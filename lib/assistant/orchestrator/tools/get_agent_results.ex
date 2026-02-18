# lib/assistant/orchestrator/tools/get_agent_results.ex — Agent result collection tool.
#
# Meta-tool the orchestrator LLM calls to collect results from dispatched
# sub-agents. Supports three polling modes:
#   - non_blocking: returns immediately with current state
#   - wait_any: blocks until at least one agent reaches a terminal state
#   - wait_all: blocks until all requested agents reach terminal states
#
# Works with the Engine's dispatched_agents state map. Does not manage
# agent lifecycle — just reads and formats current state.

defmodule Assistant.Orchestrator.Tools.GetAgentResults do
  @moduledoc """
  Orchestrator tool for collecting results from dispatched sub-agents.

  The orchestrator calls this after dispatching agents via `dispatch_agent`.
  Supports non-blocking polling, wait-for-any, and wait-for-all modes.

  ## Modes

    * `:non_blocking` — returns immediately with current agent states
    * `:wait_any` — blocks until at least one requested agent is terminal
    * `:wait_all` — blocks until all requested agents are terminal

  ## Agent States

  Terminal states: `completed`, `failed`, `timeout`
  Non-terminal: `pending`, `running`

  ## Integration

  This module does not manage agent lifecycle directly. The Engine
  maintains a `dispatched_agents` map in its GenServer state. This
  module formats that state for the LLM and optionally waits for
  terminal conditions using `Task.yield_many` references stored
  in the engine state.
  """

  require Logger

  @default_wait_ms 5_000
  @max_wait_ms 60_000
  @default_tail_lines 10
  @terminal_statuses [:completed, :failed, :timeout]
  @actionable_statuses [:completed, :failed, :timeout, :awaiting_orchestrator]

  @doc """
  Returns the OpenAI-compatible function tool definition for get_agent_results.
  """
  @spec tool_definition() :: map()
  def tool_definition do
    %{
      name: "get_agent_results",
      description: """
      Retrieve results from dispatched agents. Call this after dispatching \
      agents to collect their outputs.

      Supports non-blocking polling and bounded waits. Use this to check in \
      on progress, inspect recent transcript tails, and decide whether to \
      steer active agents.

      If called with no agent_ids, returns results for ALL dispatched agents \
      in the current turn.\
      """,
      parameters: %{
        "type" => "object",
        "properties" => %{
          "agent_ids" => %{
            "type" => "array",
            "items" => %{"type" => "string"},
            "description" =>
              "IDs of specific agents to check. Omit to check all dispatched agents."
          },
          "mode" => %{
            "type" => "string",
            "enum" => ["non_blocking", "wait_any", "wait_all"],
            "description" =>
              "Polling strategy. non_blocking returns immediately. " <>
                "wait_any waits until any requested agent reaches a terminal " <>
                "state. wait_all waits until all requested agents reach " <>
                "terminal states. Default: non_blocking."
          },
          "wait_ms" => %{
            "type" => "integer",
            "description" =>
              "Maximum wait in milliseconds for wait_any/wait_all modes. " <>
                "Default: #{@default_wait_ms}. Maximum: #{@max_wait_ms}."
          },
          "include_transcript_tail" => %{
            "type" => "boolean",
            "description" =>
              "Include each agent's recent transcript tail for progress " <>
                "inspection. Default: false."
          },
          "tail_lines" => %{
            "type" => "integer",
            "description" =>
              "How many transcript lines to include when " <>
                "include_transcript_tail=true. Default: #{@default_tail_lines}."
          }
        },
        "required" => []
      }
    }
  end

  @doc """
  Collects and formats agent results from the dispatched_agents map.

  This function is called by the Engine when processing a get_agent_results
  tool call. The Engine passes in the current dispatched_agents state.

  ## Parameters

    * `params` - LLM-provided parameters (agent_ids, mode, etc.)
    * `dispatched_agents` - Map of agent_id => agent_state from Engine state

  ## Returns

    * `{:ok, %Result{}}` with formatted agent results
    * `{:wait, mode, timeout_ms, agent_ids}` when blocking is needed
  """
  @spec execute(map(), map()) :: {:ok, Assistant.Skills.Result.t()} | {:wait, atom(), pos_integer(), [String.t()]}
  def execute(params, dispatched_agents) do
    requested_ids = resolve_agent_ids(params, dispatched_agents)
    mode = parse_mode(params["mode"])
    include_tail? = params["include_transcript_tail"] == true
    tail_lines = params["tail_lines"] || @default_tail_lines

    case mode do
      :non_blocking ->
        result = format_results(requested_ids, dispatched_agents, include_tail?, tail_lines)
        {:ok, result}

      wait_mode when wait_mode in [:wait_any, :wait_all] ->
        timeout_ms = clamp_timeout(params["wait_ms"])

        if all_terminal?(requested_ids, dispatched_agents) do
          result = format_results(requested_ids, dispatched_agents, include_tail?, tail_lines)
          {:ok, result}
        else
          {:wait, wait_mode, timeout_ms, requested_ids}
        end
    end
  end

  @doc """
  Formats agent results after a wait completes (called by Engine after yielding).

  Same as the non_blocking path of execute/2 but called after the Engine
  has updated dispatched_agents with newly-completed results.
  """
  @spec format_after_wait(map(), map(), boolean(), pos_integer()) ::
          {:ok, Assistant.Skills.Result.t()}
  def format_after_wait(params, dispatched_agents, include_tail? \\ false, tail_lines \\ @default_tail_lines) do
    requested_ids = resolve_agent_ids(params, dispatched_agents)
    result = format_results(requested_ids, dispatched_agents, include_tail?, tail_lines)
    {:ok, result}
  end

  # --- Formatting ---

  defp format_results(agent_ids, dispatched_agents, include_tail?, tail_lines) do
    agents_data =
      Enum.map(agent_ids, fn id ->
        case Map.get(dispatched_agents, id) do
          nil ->
            %{
              agent_id: id,
              status: "unknown",
              is_terminal: false,
              result: "No agent found with ID \"#{id}\"."
            }

          agent_state ->
            format_single_agent(id, agent_state, include_tail?, tail_lines)
        end
      end)

    all_done = Enum.all?(agents_data, & &1.is_terminal)

    summary = build_summary(agents_data)

    Logger.debug("get_agent_results formatted",
      agent_count: length(agents_data),
      all_done: all_done
    )

    %Assistant.Skills.Result{
      status: :ok,
      content: summary,
      metadata: %{
        agents: agents_data,
        done: all_done,
        total: length(agents_data),
        completed: Enum.count(agents_data, &(&1.status == "completed")),
        failed: Enum.count(agents_data, &(&1.status in ["failed", "timeout"])),
        awaiting: Enum.count(agents_data, &(&1.status == "awaiting_orchestrator"))
      }
    }
  end

  defp format_single_agent(id, agent_state, include_tail?, tail_lines) do
    status = to_string(agent_state[:status] || :pending)
    is_terminal = agent_state[:status] in @terminal_statuses
    is_actionable = agent_state[:status] in @actionable_statuses

    base = %{
      agent_id: id,
      status: status,
      is_terminal: is_terminal,
      is_actionable: is_actionable,
      result: agent_state[:result],
      tool_calls_used: agent_state[:tool_calls_used] || 0,
      duration_ms: agent_state[:duration_ms]
    }

    # Add awaiting_orchestrator details if present
    base =
      if agent_state[:status] == :awaiting_orchestrator do
        base
        |> Map.put(:awaiting_reason, agent_state[:reason])
        |> Map.put(:partial_history, agent_state[:partial_history])
      else
        base
      end

    if include_tail? and is_list(agent_state[:transcript_tail]) do
      tail = Enum.take(agent_state[:transcript_tail], -tail_lines)
      Map.put(base, :transcript_tail, tail)
    else
      base
    end
  end

  defp build_summary(agents_data) do
    sections =
      Enum.map_join(agents_data, "\n\n", fn agent ->
        status_icon = status_icon(agent.status)
        result_text = agent.result || "(no result yet)"

        duration =
          if agent[:duration_ms],
            do: " (#{agent.duration_ms}ms)",
            else: ""

        calls =
          if agent[:tool_calls_used] && agent.tool_calls_used > 0,
            do: ", #{agent.tool_calls_used} tool calls",
            else: ""

        awaiting_section =
          if agent.status == "awaiting_orchestrator" and agent[:awaiting_reason] do
            "\nNeeds help: #{agent.awaiting_reason}"
          else
            ""
          end

        tail_section =
          case agent[:transcript_tail] do
            lines when is_list(lines) and lines != [] ->
              "\nRecent activity:\n" <> Enum.map_join(lines, "\n", &("  " <> &1))

            _ ->
              ""
          end

        "#{status_icon} #{agent.agent_id} [#{agent.status}#{duration}#{calls}]\n#{result_text}#{awaiting_section}#{tail_section}"
      end)

    all_done = Enum.all?(agents_data, & &1.is_terminal)
    any_awaiting = Enum.any?(agents_data, &(&1.status == "awaiting_orchestrator"))

    done_line =
      cond do
        all_done ->
          "\n\nAll agents have completed."

        any_awaiting ->
          "\n\nOne or more agents are awaiting orchestrator input. " <>
            "Use send_agent_update to provide what they need, then call get_agent_results again."

        true ->
          "\n\nSome agents are still running. Call get_agent_results again to check progress."
      end

    sections <> done_line
  end

  defp status_icon("completed"), do: "[OK]"
  defp status_icon("failed"), do: "[FAIL]"
  defp status_icon("timeout"), do: "[TIMEOUT]"
  defp status_icon("running"), do: "[RUNNING]"
  defp status_icon("pending"), do: "[PENDING]"
  defp status_icon("awaiting_orchestrator"), do: "[AWAITING]"
  defp status_icon(_), do: "[?]"

  # --- Helpers ---

  defp resolve_agent_ids(params, dispatched_agents) do
    case params["agent_ids"] do
      ids when is_list(ids) and ids != [] -> ids
      _ -> Map.keys(dispatched_agents)
    end
  end

  defp parse_mode("wait_any"), do: :wait_any
  defp parse_mode("wait_all"), do: :wait_all
  defp parse_mode(_), do: :non_blocking

  defp clamp_timeout(nil), do: @default_wait_ms

  defp clamp_timeout(ms) when is_integer(ms) do
    ms |> max(0) |> min(@max_wait_ms)
  end

  defp clamp_timeout(_), do: @default_wait_ms

  defp all_terminal?(agent_ids, dispatched_agents) do
    Enum.all?(agent_ids, fn id ->
      case Map.get(dispatched_agents, id) do
        nil -> true
        state -> state[:status] in @terminal_statuses
      end
    end)
  end
end
