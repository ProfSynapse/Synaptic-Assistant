# lib/assistant/orchestrator/sub_agent/loop.ex — LLM loop logic for sub-agents.
#
# Runs inside a Task spawned by the SubAgent GenServer. Manages the
# call-LLM → parse-response → execute-tools → loop cycle, including
# interrupt checks, budget enforcement, and pause/resume for request_help.
#
# Pure-ish: communicates with the GenServer only via `send/2` messages
# (:tool_calls_update, :loop_paused) and the interrupt receive check.
#
# Related files:
#   - lib/assistant/orchestrator/sub_agent.ex (GenServer that spawns this)
#   - lib/assistant/orchestrator/sub_agent/skill_executor.ex (skill dispatch)
#   - lib/assistant/orchestrator/sub_agent/context_builder.ex (prompt assembly)
#   - lib/assistant/orchestrator/sub_agent/tool_defs.ex (tool schemas)
#   - lib/assistant/orchestrator/limits.ex (budget enforcement)

defmodule Assistant.Orchestrator.SubAgent.Loop do
  @moduledoc false

  alias Assistant.Analytics
  alias Assistant.Integrations.LLMRouter
  alias Assistant.Orchestrator.{LLMHelpers, Limits}
  alias Assistant.Orchestrator.SubAgent.{SkillExecutor, ToolDefs}
  alias Assistant.Skills.Registry

  require Logger

  @doc """
  Entry point — runs the LLM loop until text response, budget exhaustion,
  interrupt, or error. Returns a result map.
  """
  def run(context, agent_state, dispatch_params, engine_state, genserver_pid) do
    if interrupted?() do
      build_interrupted_result(context, agent_state, "before first LLM call")
    else
      run_inner(context, agent_state, dispatch_params, engine_state, genserver_pid)
    end
  end

  # --- Inner Loop ---

  defp run_inner(context, agent_state, dispatch_params, engine_state, genserver_pid) do
    model_opts = build_model_opts(dispatch_params, context, engine_state)
    model = Keyword.get(model_opts, :model)
    user_id = engine_state[:user_id] || "unknown"

    case LLMRouter.chat_completion(context.messages, model_opts, user_id) do
      {:ok, response} ->
        record_llm_analytics(engine_state, response, model, :ok)

        handle_response(
          response,
          context,
          agent_state,
          dispatch_params,
          engine_state,
          genserver_pid
        )

      {:error, reason} ->
        record_llm_analytics(engine_state, nil, model, :error, reason)

        Logger.error("Sub-agent LLM call failed",
          agent_id: dispatch_params.agent_id,
          reason: inspect(reason),
          conversation_id: engine_state[:conversation_id]
        )

        %{
          status: :failed,
          result: "LLM call failed: #{inspect(reason)}",
          tool_calls_used: agent_state.skill_calls,
          messages: context.messages
        }
    end
  end

  # --- Response Dispatch ---

  defp handle_response(response, context, agent_state, dispatch_params, engine_state, genserver_pid) do
    cond do
      LLMHelpers.text_response?(response) ->
        %{
          status: :completed,
          result: response.content,
          tool_calls_used: agent_state.skill_calls,
          messages: context.messages
        }

      LLMHelpers.tool_call_response?(response) ->
        execute_tool_calls(
          response.tool_calls,
          context,
          agent_state,
          dispatch_params,
          engine_state,
          genserver_pid
        )

      true ->
        %{
          status: :completed,
          result: response[:content] || "Agent completed with no output.",
          tool_calls_used: agent_state.skill_calls,
          messages: context.messages
        }
    end
  end

  # --- Tool Call Execution ---

  defp execute_tool_calls(
         tool_calls,
         context,
         agent_state,
         dispatch_params,
         engine_state,
         genserver_pid
       ) do
    if interrupted?() do
      build_interrupted_result(context, agent_state, "before tool execution")
    else
      execute_tool_calls_checked(
        tool_calls, context, agent_state, dispatch_params, engine_state, genserver_pid
      )
    end
  end

  defp execute_tool_calls_checked(
         tool_calls,
         context,
         agent_state,
         dispatch_params,
         engine_state,
         genserver_pid
       ) do
    call_count = length(tool_calls)

    case Limits.check_agent(agent_state, call_count) do
      {:ok, new_agent_state} ->
        {help_calls, skill_calls} =
          Enum.split_with(tool_calls, fn tc ->
            LLMHelpers.extract_function_name(tc) == "request_help"
          end)

        # Execute skill calls
        {results, final_agent_state} =
          Enum.map_reduce(skill_calls, new_agent_state, fn tc, acc_state ->
            result = SkillExecutor.execute(tc, dispatch_params, engine_state)
            {result, acc_state}
          end)

        # Report tool call count back to GenServer
        send(genserver_pid, {:tool_calls_update, final_agent_state.skill_calls})

        # Build messages: assistant tool_calls + tool results
        assistant_msg = %{role: "assistant", tool_calls: tool_calls}

        tool_msgs =
          Enum.map(results, fn {tc, result_content} ->
            %{role: "tool", tool_call_id: tc.id, content: result_content}
          end)

        new_messages = context.messages ++ [assistant_msg | tool_msgs]

        # Handle request_help pause or continue loop
        case help_calls do
          [help_tc | _] ->
            handle_pause(
              help_tc, new_messages, context, final_agent_state,
              dispatch_params, engine_state, genserver_pid
            )

          [] ->
            new_context = %{context | messages: new_messages}
            run(new_context, final_agent_state, dispatch_params, engine_state, genserver_pid)
        end

      {:error, :limit_exceeded, _details} ->
        Logger.info("Sub-agent tool budget exhausted",
          agent_id: dispatch_params.agent_id,
          used: agent_state.skill_calls,
          max: agent_state.max_skill_calls
        )

        last_text = LLMHelpers.extract_last_assistant_text(context.messages)

        %{
          status: :completed,
          result:
            last_text ||
              "Tool call limit reached (#{agent_state.skill_calls}/#{agent_state.max_skill_calls}). " <>
                "Partial work completed.",
          tool_calls_used: agent_state.skill_calls,
          messages: context.messages
        }
    end
  end

  # --- Pause / Resume (request_help) ---

  defp handle_pause(
         help_tc,
         new_messages,
         context,
         agent_state,
         dispatch_params,
         engine_state,
         genserver_pid
       ) do
    help_args = LLMHelpers.extract_function_args(help_tc)
    reason = help_args["reason"] || "Sub-agent requests assistance"
    partial_results = help_args["partial_results"]

    # Notify GenServer we're pausing
    send(genserver_pid, {:loop_paused, reason, partial_results, help_tc})

    # Block until orchestrator sends resume (5 min timeout)
    receive do
      {:resume, update} ->
        resume_content = build_resume_content(update)

        help_result_msg = %{
          role: "tool",
          tool_call_id: help_tc.id,
          content: resume_content
        }

        skill_injection_msgs = build_skill_injection_messages(update)
        resumed_messages = new_messages ++ [help_result_msg | skill_injection_msgs]

        updated_dispatch = maybe_add_skills(dispatch_params, update[:skills])
        updated_context = update_context_with_new_tools(context, resumed_messages, updated_dispatch)

        run(updated_context, agent_state, updated_dispatch, engine_state, genserver_pid)

      {:shutdown, reason} ->
        %{
          status: :failed,
          result: "Sub-agent shut down while awaiting orchestrator: #{inspect(reason)}",
          tool_calls_used: agent_state.skill_calls,
          messages: new_messages
        }
    after
      300_000 ->
        Logger.warning("Sub-agent resume timeout after 5 minutes",
          agent_id: dispatch_params.agent_id
        )

        %{
          status: :failed,
          result: "Timed out waiting for orchestrator response (5 minutes).",
          tool_calls_used: agent_state.skill_calls,
          messages: new_messages
        }
    end
  end

  # --- Resume Helpers ---

  defp build_resume_content(update) do
    parts = []

    parts =
      if update[:message] do
        ["Orchestrator response: #{update.message}" | parts]
      else
        parts
      end

    parts =
      if update[:skills] do
        ["New skills added: #{Enum.join(update.skills, ", ")}" | parts]
      else
        parts
      end

    parts =
      if update[:context_files] do
        ["New context files provided: #{Enum.join(update.context_files, ", ")}" | parts]
      else
        parts
      end

    case parts do
      [] -> "Orchestrator acknowledged your request. Continue with your mission."
      _ -> Enum.reverse(parts) |> Enum.join("\n\n")
    end
  end

  defp build_skill_injection_messages(update) do
    case update[:skills] do
      nil ->
        []

      [] ->
        []

      new_skills ->
        definitions =
          new_skills
          |> Enum.map(fn name ->
            case Registry.lookup(name) do
              {:ok, skill_def} ->
                body_preview = String.slice(skill_def.body, 0, 2000)
                "### #{skill_def.name}\n#{skill_def.description}\n\n#{body_preview}"

              {:error, :not_found} ->
                nil
            end
          end)
          |> Enum.reject(&is_nil/1)

        case definitions do
          [] ->
            []

          defs ->
            content =
              "Orchestrator update — new skills added:\n\n" <>
                Enum.join(defs, "\n\n---\n\n")

            [%{role: "user", content: content}]
        end
    end
  end

  defp maybe_add_skills(dispatch_params, nil), do: dispatch_params
  defp maybe_add_skills(dispatch_params, []), do: dispatch_params

  defp maybe_add_skills(dispatch_params, new_skills) do
    updated_skills = Enum.uniq(dispatch_params.skills ++ new_skills)
    %{dispatch_params | skills: updated_skills}
  end

  defp update_context_with_new_tools(context, new_messages, updated_dispatch) do
    new_tools = ToolDefs.build_scoped_tools(updated_dispatch.skills)

    %{
      context
      | messages: new_messages,
        tools: new_tools,
        allowed_skills: updated_dispatch.skills
    }
  end

  # --- Interrupt ---

  defp interrupted? do
    receive do
      :interrupt -> true
    after
      0 -> false
    end
  end

  defp build_interrupted_result(context, agent_state, phase) do
    last_text = LLMHelpers.extract_last_assistant_text(context.messages)

    %{
      status: :completed,
      result:
        last_text ||
          "Interrupted #{phase} (#{agent_state.skill_calls} calls completed).",
      tool_calls_used: agent_state.skill_calls,
      messages: context.messages
    }
  end

  # --- Model / Analytics ---

  defp build_model_opts(dispatch_params, context, _engine_state) do
    model =
      case dispatch_params[:model_override] do
        nil -> LLMHelpers.resolve_model(:sub_agent)
        override -> override
      end

    LLMHelpers.build_llm_opts(context.tools, model)
  end

  defp record_llm_analytics(engine_state, response, model, status, reason \\ nil) do
    usage = if is_map(response), do: response[:usage] || %{}, else: %{}

    metadata =
      %{reason: if(reason, do: inspect(reason), else: nil)}
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Map.new()

    Analytics.record_llm_call(%{
      status: status,
      scope: "sub_agent",
      model: if(is_map(response), do: response[:model] || model, else: model),
      conversation_id: engine_state[:conversation_id],
      user_id: engine_state[:user_id],
      prompt_tokens: usage[:prompt_tokens] || 0,
      completion_tokens: usage[:completion_tokens] || 0,
      total_tokens: usage[:total_tokens] || 0,
      cost: usage[:cost] || 0.0,
      metadata: metadata
    })
  end
end
