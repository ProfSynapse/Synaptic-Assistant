# lib/assistant/orchestrator/sub_agent.ex — GenServer lifecycle for sub-agents.
#
# Each sub-agent runs as a GenServer registered in Assistant.SubAgent.Registry.
# The LLM loop runs in a Task.async linked to the GenServer, sending messages
# back as progress events. This enables the sub-agent to pause (transition to
# :awaiting_orchestrator) when it calls the `request_help` tool, and resume
# when the orchestrator sends new context via `send_agent_update`.
#
# States: :running | :awaiting_orchestrator | :completed | :failed
#
# Extracted modules (SOLID decomposition):
#   - SubAgent.Loop — LLM loop, response handling, interrupt checks
#   - SubAgent.SkillExecutor — scope check, sentinel, auth, handler dispatch
#   - SubAgent.ContextBuilder — system prompt, context files, budget
#   - SubAgent.ToolDefs — use_skill + request_help tool schemas
#
# Related files:
#   - lib/assistant/orchestrator/engine.ex (spawns sub-agents via scheduler)
#   - lib/assistant/orchestrator/agent_scheduler.ex (DAG execution)
#   - lib/assistant/orchestrator/limits.ex (budget enforcement)

defmodule Assistant.Orchestrator.SubAgent do
  @moduledoc """
  GenServer lifecycle for sub-agents dispatched by the orchestrator.

  Each sub-agent runs its own short LLM loop with a scoped tool surface.
  The sub-agent only sees `use_skill` and `request_help` tools, where
  `use_skill`'s `skill` parameter is restricted to the skills the
  orchestrator granted via `dispatch_agent`.

  ## Lifecycle

  1. `start_link/1` — starts the GenServer, registers in SubAgent.Registry
  2. The GenServer spawns a Task that runs the LLM loop (via `SubAgent.Loop`)
  3. If LLM returns text -> done (`:completed`)
  4. If LLM returns `use_skill` calls -> validate scope -> sentinel check ->
     execute via SkillExecutor -> feed results back to LLM -> loop
  5. If LLM returns `request_help` call -> transition to `:awaiting_orchestrator`
  6. `resume/2` — orchestrator sends update, task resumes LLM loop
  7. If tool budget exhausted -> `:completed` with partial result
  8. If LLM error -> `:failed`

  ## States

    * `:running` — LLM loop is actively processing
    * `:awaiting_orchestrator` — paused, waiting for orchestrator update
    * `:completed` — terminal, mission finished or budget exhausted
    * `:failed` — terminal, unrecoverable error
  """

  use GenServer

  alias Assistant.Orchestrator.Limits
  alias Assistant.Orchestrator.SubAgent.{ContextBuilder, Loop}

  require Logger

  @default_max_tool_calls 5

  # ---------------------------------------------------------------
  # Client API
  # ---------------------------------------------------------------

  @doc """
  Start a sub-agent GenServer process.

  ## Parameters

    * `opts` - Keyword list with:
      * `:dispatch_params` - Map from dispatch_agent with mission, skills, etc.
      * `:dep_results` - Map of agent_id => result from dependency agents
      * `:engine_state` - Map with conversation_id, user_id, etc.

  ## Returns

    * `{:ok, pid}` on success (agent_id available via get_status/1)
    * `{:error, reason}` on failure
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    dispatch_params = Keyword.fetch!(opts, :dispatch_params)
    agent_id = dispatch_params.agent_id

    GenServer.start_link(__MODULE__, opts, name: via_tuple(agent_id))
  end

  @doc """
  Get the current status and result of a sub-agent.

  ## Returns

    * `{:ok, status_map}` with keys: `:status`, `:result`, `:tool_calls_used`,
      `:duration_ms`, `:reason` (for awaiting_orchestrator), `:partial_history`
    * `{:error, :not_found}` if agent is not registered
  """
  @spec get_status(String.t()) :: {:ok, map()} | {:error, :not_found}
  def get_status(agent_id) do
    GenServer.call(via_tuple(agent_id), :get_status)
  catch
    :exit, {:noproc, _} -> {:error, :not_found}
  end

  @doc """
  Resume a paused sub-agent with an orchestrator update.

  The sub-agent must be in `:awaiting_orchestrator` state. The update
  is injected as a tool result for the pending `request_help` call,
  and the LLM loop resumes.

  ## Parameters

    * `agent_id` - The sub-agent's identifier
    * `update` - Map with orchestrator response (`:message`, `:skills`, `:context_files`)
  """
  @spec resume(String.t(), map()) :: :ok | {:error, :not_awaiting | :not_found}
  def resume(agent_id, update) do
    GenServer.call(via_tuple(agent_id), {:resume, update})
  catch
    :exit, {:noproc, _} -> {:error, :not_found}
  end

  @doc """
  Sends an interrupt signal to a running sub-agent.

  The agent will finish its current tool call (no mid-execution abort),
  then return its partial results instead of continuing the loop.
  """
  @spec interrupt(String.t()) :: :ok | {:error, :not_found}
  def interrupt(agent_id) do
    GenServer.cast(via_tuple(agent_id), :interrupt)
  catch
    :exit, {:noproc, _} -> {:error, :not_found}
  end

  @doc """
  Synchronous execute — starts, waits for completion, returns result.

  This is the interface the AgentScheduler uses.

  ## Returns

  A map with `:status`, `:result`, `:tool_calls_used`, `:duration_ms`,
  or `{:error, {:context_budget_exceeded, details}}`.
  """
  @spec execute(map(), map(), map()) ::
          map() | {:error, {:context_budget_exceeded, map()}}
  def execute(dispatch_params, dep_results, engine_state) do
    agent_id = dispatch_params.agent_id

    opts = [
      dispatch_params: dispatch_params,
      dep_results: dep_results,
      engine_state: engine_state
    ]

    # Use GenServer.start (NOT start_link) to avoid linking the GenServer
    # to the calling Task. The monitor alone is sufficient for detecting
    # GenServer termination.
    case GenServer.start(__MODULE__, opts, name: via_tuple(agent_id)) do
      {:ok, pid} ->
        ref = Process.monitor(pid)
        wait_for_completion(ref)

      {:error, reason} ->
        %{
          status: :failed,
          result: "Failed to start sub-agent: #{inspect(reason)}",
          tool_calls_used: 0,
          duration_ms: 0,
          messages: []
        }
    end
  end

  # ---------------------------------------------------------------
  # GenServer Callbacks
  # ---------------------------------------------------------------

  @impl true
  def init(opts) do
    dispatch_params = Keyword.fetch!(opts, :dispatch_params)
    dep_results = Keyword.get(opts, :dep_results, %{})
    engine_state = Keyword.get(opts, :engine_state, %{})

    agent_id = dispatch_params.agent_id
    started_at = System.monotonic_time(:millisecond)

    # Each sub-agent gets its own conversation_id.
    sub_conversation_id = Ecto.UUID.generate()
    parent_conversation_id = engine_state[:conversation_id]

    sub_engine_state =
      engine_state
      |> Map.put(:conversation_id, sub_conversation_id)
      |> Map.put(:parent_conversation_id, parent_conversation_id)
      |> Map.put(:agent_type, :sub_agent)

    Logger.info("Sub-agent starting",
      agent_id: agent_id,
      skills: dispatch_params.skills,
      conversation_id: sub_conversation_id,
      parent_conversation_id: parent_conversation_id
    )

    state = %{
      agent_id: agent_id,
      dispatch_params: dispatch_params,
      dep_results: dep_results,
      engine_state: sub_engine_state,
      started_at: started_at,
      status: :running,
      result: nil,
      tool_calls_used: 0,
      duration_ms: nil,
      messages: nil,
      awaiting_reason: nil,
      awaiting_partial_history: nil,
      pending_help_tc: nil,
      loop_task: nil,
      loop_ref: nil,
      interrupted: false
    }

    {:ok, state, {:continue, :start_loop}}
  end

  @impl true
  def handle_continue(:start_loop, state) do
    case ContextBuilder.build(state.dispatch_params, state.dep_results, state.engine_state) do
      {:error, {:context_budget_exceeded, _details}} = error ->
        Logger.warning("Sub-agent aborted — context files exceed token budget",
          agent_id: state.agent_id,
          conversation_id: state.engine_state[:conversation_id]
        )

        final_state = %{state | status: :failed, result: error}
        {:stop, {:shutdown, error}, final_state}

      {:ok, context} ->
        max_calls = state.dispatch_params[:max_tool_calls] || @default_max_tool_calls
        agent_limit_state = Limits.new_agent_state(max_skill_calls: max_calls)

        parent = self()

        task =
          Task.async(fn ->
            Loop.run(
              context,
              agent_limit_state,
              state.dispatch_params,
              state.engine_state,
              parent
            )
          end)

        {:noreply, %{state | loop_task: task, loop_ref: task.ref}}
    end
  end

  @impl true
  def handle_call(:get_status, _from, state) do
    status_map = %{
      status: state.status,
      result: extract_result_text(state.result),
      tool_calls_used: state.tool_calls_used,
      duration_ms: state.duration_ms || elapsed_ms(state.started_at)
    }

    status_map =
      if state.status == :awaiting_orchestrator do
        status_map
        |> Map.put(:reason, state.awaiting_reason)
        |> Map.put(:partial_history, state.awaiting_partial_history)
      else
        status_map
      end

    {:reply, {:ok, status_map}, state}
  end

  @impl true
  def handle_call({:resume, update}, _from, state) do
    if state.status != :awaiting_orchestrator do
      {:reply, {:error, :not_awaiting}, state}
    else
      Logger.info("Sub-agent resuming after orchestrator update",
        agent_id: state.agent_id,
        has_new_skills: update[:skills] != nil,
        has_message: update[:message] != nil
      )

      send(state.loop_task.pid, {:resume, update})

      {:reply, :ok,
       %{state | status: :running, awaiting_reason: nil, awaiting_partial_history: nil}}
    end
  end

  @impl true
  def handle_cast(:interrupt, state) do
    if state.status == :running and state.loop_task != nil do
      Logger.info("Sub-agent received interrupt signal",
        agent_id: state.agent_id,
        conversation_id: state.engine_state[:conversation_id]
      )

      send(state.loop_task.pid, :interrupt)
      {:noreply, %{state | interrupted: true}}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info({:loop_paused, reason, partial_history, help_tc}, state) do
    Logger.info("Sub-agent paused — awaiting orchestrator",
      agent_id: state.agent_id,
      reason: reason
    )

    {:noreply,
     %{
       state
       | status: :awaiting_orchestrator,
         awaiting_reason: reason,
         awaiting_partial_history: partial_history,
         pending_help_tc: help_tc
     }}
  end

  @impl true
  def handle_info({:tool_calls_update, count}, state) do
    {:noreply, %{state | tool_calls_used: count}}
  end

  @impl true
  def handle_info({ref, result}, %{loop_ref: ref} = state) do
    # Task completed normally
    Process.demonitor(ref, [:flush])
    duration_ms = elapsed_ms(state.started_at)

    final_result =
      case result do
        %{status: _} = map ->
          Map.put(map, :duration_ms, duration_ms)

        other ->
          %{
            status: :completed,
            result: other,
            tool_calls_used: state.tool_calls_used,
            duration_ms: duration_ms
          }
      end

    Logger.info("Sub-agent completed",
      agent_id: state.agent_id,
      status: final_result.status,
      tool_calls_used: final_result[:tool_calls_used] || state.tool_calls_used,
      duration_ms: duration_ms,
      conversation_id: state.engine_state[:conversation_id],
      parent_conversation_id: state.engine_state[:parent_conversation_id]
    )

    final_state = %{
      state
      | status: final_result.status,
        result: final_result.result,
        tool_calls_used: final_result[:tool_calls_used] || state.tool_calls_used,
        duration_ms: duration_ms,
        messages: final_result[:messages]
    }

    {:stop, {:shutdown, build_final_result_map(final_state)}, final_state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{loop_ref: ref} = state) do
    # Task crashed
    duration_ms = elapsed_ms(state.started_at)

    Logger.error("Sub-agent loop task crashed",
      agent_id: state.agent_id,
      reason: inspect(reason)
    )

    final_state = %{
      state
      | status: :failed,
        result: "Sub-agent loop crashed: #{inspect(reason)}",
        duration_ms: duration_ms
    }

    {:stop, {:shutdown, build_final_result_map(final_state)}, final_state}
  end

  # Catch-all for unrelated messages
  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  # ---------------------------------------------------------------
  # Private Helpers
  # ---------------------------------------------------------------

  defp wait_for_completion(monitor_ref) do
    receive do
      {:DOWN, ^monitor_ref, :process, _pid,
       {:shutdown, {:error, {:context_budget_exceeded, _}} = error}} ->
        error

      {:DOWN, ^monitor_ref, :process, _pid, {:shutdown, %{status: _} = result_map}} ->
        result_map

      {:DOWN, ^monitor_ref, :process, _pid, :normal} ->
        %{
          status: :completed,
          result: "Agent completed (status unavailable after shutdown).",
          tool_calls_used: 0,
          duration_ms: 0
        }

      {:DOWN, ^monitor_ref, :process, _pid, reason} ->
        %{
          status: :failed,
          result: "Sub-agent process exited: #{inspect(reason)}",
          tool_calls_used: 0,
          duration_ms: 0
        }
    after
      120_000 ->
        %{
          status: :timeout,
          result: "Sub-agent timed out after 120 seconds",
          tool_calls_used: 0,
          duration_ms: 120_000
        }
    end
  end

  defp build_final_result_map(state) do
    %{
      status: state.status,
      result: extract_result_text(state.result),
      tool_calls_used: state.tool_calls_used,
      duration_ms: state.duration_ms,
      messages: state.messages
    }
  end

  defp extract_result_text({:error, {:context_budget_exceeded, details}}) do
    "Context budget exceeded: #{inspect(details)}"
  end

  defp extract_result_text(text) when is_binary(text), do: text
  defp extract_result_text(nil), do: nil
  defp extract_result_text(other), do: inspect(other)

  defp elapsed_ms(started_at) do
    System.monotonic_time(:millisecond) - started_at
  end

  defp via_tuple(agent_id) do
    {:via, Registry, {Assistant.SubAgent.Registry, agent_id}}
  end
end
