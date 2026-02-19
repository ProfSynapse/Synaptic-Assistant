# lib/assistant/orchestrator/loop_runner.ex — Pure-function LLM loop logic.
#
# Extracted from the Engine GenServer to be stateless and testable.
# One iteration = call LLM → parse response → route tool calls → return
# next action. The Engine calls run_iteration/3 and handles state updates
# and side effects.
#
# Related files:
#   - lib/assistant/orchestrator/engine.ex (GenServer that calls this)
#   - lib/assistant/orchestrator/context.ex (builds LLM request payloads)
#   - lib/assistant/orchestrator/llm_helpers.ex (shared LLM helpers)
#   - lib/assistant/orchestrator/tools/get_skill.ex
#   - lib/assistant/orchestrator/tools/dispatch_agent.ex
#   - lib/assistant/orchestrator/tools/get_agent_results.ex
#   - lib/assistant/orchestrator/tools/send_agent_update.ex
#   - lib/assistant/resilience/circuit_breaker.ex

defmodule Assistant.Orchestrator.LoopRunner do
  @moduledoc """
  Pure-function LLM loop logic for the orchestration engine.

  Each call to `run_iteration/3` performs one LLM round-trip:
  call the LLM, parse the response, and return a tagged result
  describing what the Engine should do next.

  ## Return Values

    * `{:text, content, usage}` — LLM returned a final text response
    * `{:tool_calls, processed_results, pending_dispatches, usage}` —
      LLM returned tool calls; some executed locally, some are dispatches
    * `{:wait, mode, timeout_ms, agent_ids, tool_call_id, usage}` —
      get_agent_results requested a blocking wait
    * `{:error, reason}` — LLM call failed

  The Engine interprets these results, updates its GenServer state, and
  decides whether to loop again or respond to the user.
  """

  alias Assistant.Orchestrator.{Context, LLMHelpers}
  alias Assistant.Orchestrator.Tools.{DispatchAgent, GetAgentResults, GetSkill, SendAgentUpdate}
  alias Assistant.Skills.Result, as: SkillResult

  require Logger

  @llm_client Application.compile_env(
                :assistant,
                :llm_client,
                Assistant.Integrations.OpenRouter
              )

  @max_orchestrator_iterations 10

  @doc """
  Run one LLM iteration: call the LLM with current messages and process the response.

  ## Parameters

    * `messages` - Full message list (system already prepended by Engine)
    * `loop_state` - Current LoopState map from the Engine
    * `opts` - Options forwarded to LLM client (`:model`, `:tools`, etc.)

  ## Returns

  See module doc for return value descriptions.
  """
  @spec run_iteration([map()], map(), keyword()) ::
          {:text, String.t(), map()}
          | {:tool_calls, [map()], [map()], map()}
          | {:wait, atom(), pos_integer(), [String.t()], String.t(), map()}
          | {:error, term()}
  def run_iteration(messages, loop_state, opts \\ []) do
    tools = Keyword.get(opts, :tools, Context.tool_definitions())

    model =
      case Keyword.get(opts, :model) do
        nil -> LLMHelpers.resolve_model(:orchestrator)
        override -> override
      end

    llm_opts = LLMHelpers.build_llm_opts(tools, model)

    case @llm_client.chat_completion(messages, llm_opts) do
      {:ok, response} ->
        process_response(response, loop_state)

      {:error, reason} ->
        Logger.error("LLM call failed in loop runner",
          reason: inspect(reason),
          conversation_id: loop_state[:conversation_id]
        )

        {:error, reason}
    end
  end

  @doc """
  Returns the maximum number of orchestrator loop iterations per turn.
  """
  @spec max_iterations() :: pos_integer()
  def max_iterations, do: @max_orchestrator_iterations

  # --- Response Processing ---

  defp process_response(response, loop_state) do
    usage = response[:usage] || %{}

    cond do
      # Text-only response — terminal
      has_text_no_tools?(response) ->
        {:text, response.content, usage}

      # Tool calls present
      has_tool_calls?(response) ->
        process_tool_calls(response.tool_calls, loop_state, usage)

      # Unexpected: no content and no tool calls
      true ->
        {:text, response[:content] || "", usage}
    end
  end

  defp has_text_no_tools?(response), do: LLMHelpers.text_response?(response)
  defp has_tool_calls?(response), do: LLMHelpers.tool_call_response?(response)

  # --- Tool Call Processing ---

  defp process_tool_calls(tool_calls, loop_state, usage) do
    {local_results, pending_dispatches, wait_signal} =
      Enum.reduce(tool_calls, {[], [], nil}, fn tc, {locals, dispatches, wait} ->
        case route_tool_call(tc, loop_state) do
          {:local, result} ->
            {[{tc, result} | locals], dispatches, wait}

          {:dispatch, dispatch_params} ->
            {locals, [{tc, dispatch_params} | dispatches], wait}

          {:wait, mode, timeout_ms, agent_ids} ->
            {locals, dispatches, {mode, timeout_ms, agent_ids, tc}}
        end
      end)

    local_results = Enum.reverse(local_results)
    pending_dispatches = Enum.reverse(pending_dispatches)

    case wait_signal do
      {mode, timeout_ms, agent_ids, tc} ->
        # get_agent_results requested a blocking wait — Engine must handle it
        {:wait, mode, timeout_ms, agent_ids, tc.id, usage}

      nil when pending_dispatches != [] ->
        # Has dispatch_agent calls — Engine must spawn agents
        {:tool_calls, local_results, pending_dispatches, usage}

      nil ->
        # Only local tool calls (get_skill) — results ready to feed back
        {:tool_calls, local_results, [], usage}
    end
  end

  defp route_tool_call(tc, loop_state) do
    name = LLMHelpers.extract_function_name(tc)
    args = LLMHelpers.extract_function_args(tc)

    case name do
      "get_skill" ->
        {:ok, result} = GetSkill.execute(args, nil)
        {:local, result}

      "dispatch_agent" ->
        context = build_skill_context(loop_state)
        {:ok, result} = DispatchAgent.execute(args, context)

        if result.status == :ok and result.metadata[:dispatch] do
          {:dispatch, result.metadata.dispatch}
        else
          # Validation error — return as local result
          {:local, result}
        end

      "get_agent_results" ->
        dispatched = loop_state[:dispatched_agents] || %{}

        case GetAgentResults.execute(args, dispatched) do
          {:ok, result} ->
            {:local, result}

          {:wait, mode, timeout_ms, agent_ids} ->
            {:wait, mode, timeout_ms, agent_ids}
        end

      "send_agent_update" ->
        {:ok, result} = SendAgentUpdate.execute(args, nil)
        {:local, result}

      unknown ->
        result = %SkillResult{
          status: :error,
          content: "Unknown tool: #{unknown}"
        }

        {:local, result}
    end
  end

  # --- Message Building Helpers ---

  @doc """
  Formats a list of local tool call results as message entries
  suitable for appending to the conversation.

  Returns a list of maps with `role: "tool"` and the result content.
  """
  @spec format_tool_results([{map(), SkillResult.t()}]) :: [map()]
  def format_tool_results(results) do
    Enum.map(results, fn {tc, result} ->
      %{
        role: "tool",
        tool_call_id: tc.id,
        content: result.content
      }
    end)
  end

  @doc """
  Builds an assistant message containing tool calls, suitable for
  appending to the conversation history.
  """
  @spec format_assistant_tool_calls([map()]) :: map()
  def format_assistant_tool_calls(tool_calls) do
    %{
      role: "assistant",
      tool_calls: tool_calls
    }
  end

  # --- Private Helpers ---

  defp build_skill_context(loop_state) do
    %Assistant.Skills.Context{
      conversation_id: loop_state[:conversation_id] || "unknown",
      execution_id: Ecto.UUID.generate(),
      user_id: loop_state[:user_id] || "unknown",
      channel: loop_state[:channel],
      integrations: Assistant.Integrations.Registry.default_integrations()
    }
  end
end
