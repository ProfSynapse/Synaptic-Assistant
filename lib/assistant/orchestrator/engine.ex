# lib/assistant/orchestrator/engine.ex — GenServer per conversation.
#
# One Engine process per active conversation. Manages the LLM loop, sub-agent
# dispatch, result collection, and circuit breaker enforcement. The Engine is
# the only stateful component — LoopRunner and AgentScheduler are pure functions
# that the Engine calls.
#
# Supervision: started under Assistant.Orchestrator.ConversationSupervisor
# (a DynamicSupervisor) via start_conversation/2. Each Engine also starts
# its own Task.Supervisor for sub-agent tasks.
#
# Related files:
#   - lib/assistant/orchestrator/loop_runner.ex (pure LLM loop logic)
#   - lib/assistant/orchestrator/context.ex (context assembly)
#   - lib/assistant/orchestrator/agent_scheduler.ex (DAG + wave execution)
#   - lib/assistant/resilience/circuit_breaker.ex (four-level limits)
#   - lib/assistant/application.ex (supervision tree)

defmodule Assistant.Orchestrator.Engine do
  @moduledoc """
  GenServer per conversation managing the orchestration loop.

  ## Responsibilities

    * Accept user messages and drive the LLM loop to produce a response
    * Dispatch sub-agents via the AgentScheduler when the LLM requests it
    * Handle blocking waits (`get_agent_results` with `wait_any`/`wait_all`)
    * Enforce circuit breaker limits at turn and conversation level
    * Track dispatched agent state for result collection

  ## Modes

    * `:multi_agent` — (default) Full orchestrator with sub-agent dispatch.
      The LLM sees get_skill, dispatch_agent, get_agent_results tools.
    * `:single_loop` — Voice/simple channel mode. Single LLM loop with
      direct skill execution, no sub-agent dispatch.

  ## LoopState

  Internal state threaded through the LLM loop. Contains conversation
  metadata, circuit breaker counters, dispatched agent tracking, and
  the message history for the current turn.
  """

  use GenServer

  alias Assistant.Orchestrator.{AgentScheduler, Context, LoopRunner, SubAgent}
  alias Assistant.Orchestrator.Tools.{DispatchAgent, GetAgentResults}
  alias Assistant.Resilience.CircuitBreaker

  require Logger

  @default_mode :multi_agent

  # --- Client API ---

  @doc """
  Starts an Engine process for the given conversation.

  ## Parameters

    * `conversation_id` - Unique identifier for the conversation
    * `opts` - Options:
      * `:user_id` - User identifier (default: "unknown")
      * `:channel` - Channel identifier (default: "unknown")
      * `:mode` - `:multi_agent` or `:single_loop` (default: `:multi_agent`)

  ## Returns

    * `{:ok, pid}` on success
    * `{:error, reason}` on failure
  """
  @spec start_link(String.t(), keyword()) :: GenServer.on_start()
  def start_link(conversation_id, opts \\ []) do
    GenServer.start_link(__MODULE__, {conversation_id, opts},
      name: via_tuple(conversation_id)
    )
  end

  @doc """
  Sends a user message to the engine and receives the assistant's response.

  This is the main entry point. It triggers the LLM loop which may dispatch
  sub-agents, wait for results, and iterate until a final text response is
  produced or limits are hit.

  ## Parameters

    * `conversation_id` - The conversation to send the message to
    * `message` - The user's message text

  ## Returns

    * `{:ok, response_text}` — Final assistant response
    * `{:error, reason}` — LLM failure, timeout, or engine not found
  """
  @spec send_message(String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def send_message(conversation_id, message) do
    GenServer.call(via_tuple(conversation_id), {:send_message, message}, :timer.seconds(120))
  end

  @doc """
  Returns the current state of the engine for debugging/monitoring.
  """
  @spec get_state(String.t()) :: {:ok, map()} | {:error, :not_found}
  def get_state(conversation_id) do
    GenServer.call(via_tuple(conversation_id), :get_state)
  catch
    :exit, {:noproc, _} -> {:error, :not_found}
  end

  # --- GenServer Callbacks ---

  @impl true
  def init({conversation_id, opts}) do
    user_id = Keyword.get(opts, :user_id, "unknown")
    channel = Keyword.get(opts, :channel, "unknown")
    mode = Keyword.get(opts, :mode, @default_mode)

    # Start a per-conversation Task.Supervisor for sub-agent tasks
    {:ok, agent_supervisor} =
      Task.Supervisor.start_link(max_children: 10)

    state = %{
      conversation_id: conversation_id,
      user_id: user_id,
      channel: channel,
      mode: mode,
      agent_supervisor: agent_supervisor,
      messages: [],
      dispatched_agents: %{},
      agent_tasks: %{},
      turn_state: CircuitBreaker.new_turn_state(),
      conversation_state: CircuitBreaker.new_conversation_state(),
      iteration_count: 0,
      skipped: [],
      total_usage: %{prompt_tokens: 0, completion_tokens: 0},
      # Usage-based context trimming: the prompt_tokens from the most recent
      # LLM response tells us exactly how many tokens the current history uses.
      # Paired with the message count at that point, we can identify which
      # messages are "new" (needing estimation) vs "known" (covered by baseline).
      last_prompt_tokens: nil,
      last_message_count: 0
    }

    Logger.info("Engine started",
      conversation_id: conversation_id,
      user_id: user_id,
      channel: channel,
      mode: mode
    )

    {:ok, state}
  end

  @impl true
  def handle_call({:send_message, message}, _from, state) do
    # Reset per-turn state for each new user message
    state =
      state
      |> Map.put(:turn_state, CircuitBreaker.new_turn_state())
      |> Map.put(:iteration_count, 0)
      |> Map.put(:dispatched_agents, %{})
      |> Map.put(:agent_tasks, %{})
      |> Map.put(:skipped, [])

    # Append user message to history
    user_msg = %{role: "user", content: message}
    state = Map.update!(state, :messages, &(&1 ++ [user_msg]))

    # Run the orchestration loop
    case run_loop(state) do
      {:ok, response_text, final_state} ->
        # Append assistant response to history
        assistant_msg = %{role: "assistant", content: response_text}
        final_state = Map.update!(final_state, :messages, &(&1 ++ [assistant_msg]))
        {:reply, {:ok, response_text}, final_state}

      {:error, reason, final_state} ->
        {:reply, {:error, reason}, final_state}
    end
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    public_state = %{
      conversation_id: state.conversation_id,
      user_id: state.user_id,
      channel: state.channel,
      mode: state.mode,
      message_count: length(state.messages),
      dispatched_agents: Map.keys(state.dispatched_agents),
      iteration_count: state.iteration_count,
      total_usage: state.total_usage
    }

    {:reply, {:ok, public_state}, state}
  end

  @impl true
  def terminate(reason, state) do
    Logger.info("Engine terminating",
      conversation_id: state.conversation_id,
      reason: inspect(reason)
    )

    # Shut down the agent supervisor (kills running sub-agent tasks)
    if Process.alive?(state.agent_supervisor) do
      Supervisor.stop(state.agent_supervisor, :shutdown, 5_000)
    end

    :ok
  end

  # --- Orchestration Loop ---

  defp run_loop(state) do
    max = LoopRunner.max_iterations()

    if state.iteration_count >= max do
      Logger.warning("Max orchestrator iterations reached",
        conversation_id: state.conversation_id,
        iterations: state.iteration_count
      )

      {:ok, "I reached my processing limit for this turn. Here's what I have so far.", state}
    else
      state = Map.update!(state, :iteration_count, &(&1 + 1))

      # Build context and run one LLM iteration
      loop_state = build_loop_state(state)
      context = Context.build(loop_state, state.messages)

      messages = [context.system | context.messages]
      opts = [tools: context.tools]

      case LoopRunner.run_iteration(messages, loop_state, opts) do
        {:text, content, usage} ->
          state = accumulate_usage(state, usage)
          {:ok, content, state}

        {:tool_calls, local_results, pending_dispatches, usage} ->
          state = accumulate_usage(state, usage)
          handle_tool_calls(state, local_results, pending_dispatches)

        {:wait, mode, timeout_ms, agent_ids, tool_call_id, usage} ->
          state = accumulate_usage(state, usage)
          handle_wait(state, mode, timeout_ms, agent_ids, tool_call_id)

        {:error, reason} ->
          {:error, reason, state}
      end
    end
  end

  # --- Tool Call Handling ---

  defp handle_tool_calls(state, local_results, pending_dispatches) do
    # Add the assistant's tool call message to history
    all_tool_calls =
      Enum.map(local_results, fn {tc, _result} -> tc end) ++
        Enum.map(pending_dispatches, fn {tc, _params} -> tc end)

    state =
      if all_tool_calls != [] do
        assistant_msg = LoopRunner.format_assistant_tool_calls(all_tool_calls)
        Map.update!(state, :messages, &(&1 ++ [assistant_msg]))
      else
        state
      end

    # Add local tool results to message history
    tool_messages = LoopRunner.format_tool_results(local_results)
    state = Map.update!(state, :messages, &(&1 ++ tool_messages))

    # Handle dispatches if present
    state = handle_dispatches(state, pending_dispatches)

    # Continue the loop
    run_loop(state)
  end

  defp handle_dispatches(state, []), do: state

  defp handle_dispatches(state, pending_dispatches) do
    # Check per-turn agent dispatch limit
    dispatch_count = length(pending_dispatches)

    case DispatchAgent.check_dispatch_limit(state.turn_state, dispatch_count) do
      {:ok, new_turn_state} ->
        state = Map.put(state, :turn_state, new_turn_state)

        # Build dispatches map for the scheduler
        dispatches =
          Enum.into(pending_dispatches, %{}, fn {_tc, params} ->
            {params.agent_id, params}
          end)

        # Execute via scheduler (handles DAG, waves, parallelism)
        execute_fn = fn dispatch_params, dep_results ->
          execute_sub_agent(dispatch_params, dep_results, state)
        end

        case AgentScheduler.execute(dispatches, state.agent_supervisor, execute_fn) do
          {:ok, results} ->
            # Store results in dispatched_agents
            new_dispatched =
              Map.merge(state.dispatched_agents, results)

            # Add tool result messages for each dispatch_agent tool call
            dispatch_result_messages =
              Enum.map(pending_dispatches, fn {tc, params} ->
                agent_result = Map.get(results, params.agent_id, %{status: :pending})
                status = agent_result[:status] || :completed
                result_text = agent_result[:result] || "Agent completed."

                %{
                  role: "tool",
                  tool_call_id: tc.id,
                  content:
                    "Agent \"#{params.agent_id}\" dispatched and #{status}. " <>
                      "Use get_agent_results to inspect full results.\n\n" <>
                      "Summary: #{result_text}"
                }
              end)

            state
            |> Map.put(:dispatched_agents, new_dispatched)
            |> Map.update!(:messages, &(&1 ++ dispatch_result_messages))

          {:error, reason} ->
            Logger.error("Agent scheduler failed",
              conversation_id: state.conversation_id,
              reason: inspect(reason)
            )

            # Add error messages for each dispatch
            error_messages =
              Enum.map(pending_dispatches, fn {tc, _params} ->
                %{
                  role: "tool",
                  tool_call_id: tc.id,
                  content: "Failed to dispatch agents: #{inspect(reason)}"
                }
              end)

            Map.update!(state, :messages, &(&1 ++ error_messages))
        end

      {:error, :limit_exceeded, details} ->
        Logger.warning("Agent dispatch limit exceeded",
          conversation_id: state.conversation_id,
          details: inspect(details)
        )

        # Add limit-exceeded messages for each dispatch tool call
        limit_messages =
          Enum.map(pending_dispatches, fn {tc, _params} ->
            %{
              role: "tool",
              tool_call_id: tc.id,
              content:
                "Agent dispatch limit reached (#{details.used}/#{details.max} agents this turn). " <>
                  "Complete existing agents before dispatching more, or synthesize a response " <>
                  "with current results."
            }
          end)

        Map.update!(state, :messages, &(&1 ++ limit_messages))
    end
  end

  # --- Wait Handling ---

  defp handle_wait(state, mode, timeout_ms, agent_ids, tool_call_id) do
    # Wait for agents using the scheduler
    completed =
      AgentScheduler.wait_for_agents(
        state.agent_tasks,
        agent_ids,
        mode,
        timeout_ms
      )

    # Merge completed results into dispatched_agents
    new_dispatched = Map.merge(state.dispatched_agents, completed)
    state = Map.put(state, :dispatched_agents, new_dispatched)

    # Format post-wait results
    {:ok, wait_result} =
      GetAgentResults.format_after_wait(
        %{"agent_ids" => agent_ids},
        new_dispatched,
        false
      )

    # Add the original tool call and its result to history
    wait_tool_call_msg = %{
      role: "assistant",
      tool_calls: [
        %{
          id: tool_call_id,
          type: "function",
          function: %{
            name: "get_agent_results",
            arguments:
              Jason.encode!(%{
                "agent_ids" => agent_ids,
                "mode" => to_string(mode)
              })
          }
        }
      ]
    }

    wait_result_msg = %{
      role: "tool",
      tool_call_id: tool_call_id,
      content: wait_result.content
    }

    state =
      Map.update!(state, :messages, &(&1 ++ [wait_tool_call_msg, wait_result_msg]))

    # Continue the loop
    run_loop(state)
  end

  # --- Sub-Agent Execution ---

  defp execute_sub_agent(dispatch_params, dep_results, engine_state) do
    SubAgent.execute(dispatch_params, dep_results, engine_state)
  end

  # --- Helpers ---

  defp build_loop_state(state) do
    %{
      conversation_id: state.conversation_id,
      user_id: state.user_id,
      channel: state.channel,
      mode: state.mode,
      dispatched_agents: state.dispatched_agents,
      turn_state: state.turn_state,
      conversation_state: state.conversation_state,
      iteration_count: state.iteration_count,
      # Usage-based context trimming data for Context.build
      last_prompt_tokens: state.last_prompt_tokens,
      last_message_count: state.last_message_count
    }
  end

  defp accumulate_usage(state, usage) when is_map(usage) do
    state
    |> Map.update!(:total_usage, fn current ->
      %{
        prompt_tokens: (current[:prompt_tokens] || 0) + (usage[:prompt_tokens] || 0),
        completion_tokens:
          (current[:completion_tokens] || 0) + (usage[:completion_tokens] || 0)
      }
    end)
    # Track the most recent prompt_tokens for usage-based context trimming.
    # This tells Context how many tokens the history consumed at this point.
    |> Map.put(:last_prompt_tokens, usage[:prompt_tokens])
    |> Map.put(:last_message_count, length(state.messages))
  end

  defp accumulate_usage(state, _usage), do: state

  defp via_tuple(conversation_id) do
    {:via, Registry, {Assistant.Orchestrator.EngineRegistry, conversation_id}}
  end
end
