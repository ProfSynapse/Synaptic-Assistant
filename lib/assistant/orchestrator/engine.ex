# lib/assistant/orchestrator/engine.ex — GenServer per user conversation.
#
# One Engine process per active user. Registered by user_id UUID in the
# EngineRegistry. Manages the LLM loop, sub-agent dispatch, result collection,
# and circuit breaker enforcement. The Engine is the only stateful component —
# LoopRunner and AgentScheduler are pure functions that the Engine calls.
#
# Messages are persisted to DB at the end of each turn via async
# batch_append_messages. On restart, the Engine hydrates from DB.
#
# Supervision: started under Assistant.Orchestrator.ConversationSupervisor
# (a DynamicSupervisor). Each Engine also starts its own Task.Supervisor
# for sub-agent tasks.
#
# Related files:
#   - lib/assistant/orchestrator/loop_runner.ex (pure LLM loop logic)
#   - lib/assistant/orchestrator/context.ex (context assembly)
#   - lib/assistant/orchestrator/agent_scheduler.ex (DAG + wave execution)
#   - lib/assistant/orchestrator/nudger.ex (error→hint mapping from YAML)
#   - lib/assistant/resilience/circuit_breaker.ex (four-level limits)
#   - lib/assistant/memory/store.ex (batch message persistence)
#   - lib/assistant/application.ex (supervision tree)

defmodule Assistant.Orchestrator.Engine do
  @moduledoc """
  GenServer per user managing the orchestration loop.

  Registered by `user_id` UUID in the EngineRegistry. Each user has one
  Engine process and one perpetual conversation (conversation_id).

  ## Responsibilities

    * Accept user messages and drive the LLM loop to produce a response
    * Dispatch sub-agents via the AgentScheduler when the LLM requests it
    * Handle blocking waits (`get_agent_results` with `wait_any`/`wait_all`)
    * Enforce circuit breaker limits at turn and conversation level
    * Track dispatched agent state for result collection
    * Persist all turn messages to DB asynchronously at turn end
    * Hydrate from DB messages on restart

  ## Modes

    * `:multi_agent` — (default) Full orchestrator with sub-agent dispatch.
      The LLM sees get_skill, dispatch_agent, get_agent_results,
      send_agent_update tools.
    * `:single_loop` — Voice/simple channel mode. Single LLM loop with
      direct skill execution, no sub-agent dispatch.

  ## LoopState

  Internal state threaded through the LLM loop. Contains conversation
  metadata, circuit breaker counters, dispatched agent tracking, and
  the message history for the current turn.
  """

  use GenServer

  alias Assistant.Config.Loader, as: ConfigLoader
  alias Assistant.Memory.Store
  alias Assistant.Orchestrator.{AgentScheduler, Context, Limits, LoopRunner, Nudger, SubAgent}
  alias Assistant.Orchestrator.Tools.{DispatchAgent, GetAgentResults}
  alias Assistant.Resilience.CircuitBreaker
  alias Assistant.Scheduler.Workers.{MemorySaveWorker, TrajectoryExportWorker}

  require Logger

  @default_mode :multi_agent

  # Number of recent messages to hydrate from DB on engine restart
  @hydrate_message_limit 50

  # Max message size in bytes (~50K tokens). Rejects obviously oversized
  # input before it enters the LLM loop. This is a per-message sanity
  # check — the Engine's compaction system handles total context separately.
  @max_message_bytes 200_000

  # --- Client API ---

  @doc """
  Starts an Engine process for the given user.

  The Engine is registered by `user_id` UUID in the EngineRegistry. Each
  user has at most one running Engine process at a time.

  ## Parameters

    * `user_id` - User UUID (registration key in EngineRegistry)
    * `opts` - Options:
      * `:conversation_id` - Perpetual conversation UUID (required)
      * `:channel` - Channel identifier (default: "unknown")
      * `:mode` - `:multi_agent` or `:single_loop` (default: `:multi_agent`)

  ## Returns

    * `{:ok, pid}` on success
    * `{:error, reason}` on failure
  """
  @spec start_link(String.t(), keyword()) :: GenServer.on_start()
  def start_link(user_id, opts \\ []) do
    GenServer.start_link(__MODULE__, {user_id, opts}, name: via_tuple(user_id))
  end

  @doc """
  Sends a user message to the engine and receives the assistant's response.

  This is the main entry point. It triggers the LLM loop which may dispatch
  sub-agents, wait for results, and iterate until a final text response is
  produced or limits are hit.

  ## Parameters

    * `user_id` - The user UUID whose engine to send the message to
    * `message` - The user's message text
    * `opts` - Optional keyword list:
      * `:metadata` - Persisted metadata for the user message row

  ## Returns

    * `{:ok, response_text}` — Final assistant response
    * `{:error, reason}` — LLM failure, timeout, or engine not found
  """
  @spec send_message(String.t(), String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def send_message(user_id, message, opts \\ []) do
    if byte_size(message) > @max_message_bytes do
      {:error, :message_too_long}
    else
      metadata = normalize_message_metadata(Keyword.get(opts, :metadata))
      timeout = Application.get_env(:assistant, :engine_call_timeout, 300_000)
      GenServer.call(via_tuple(user_id), {:send_message, message, metadata}, timeout)
    end
  end

  @doc """
  Returns the current state of the engine for debugging/monitoring.
  """
  @spec get_state(String.t()) :: {:ok, map()} | {:error, :not_found}
  def get_state(user_id) do
    GenServer.call(via_tuple(user_id), :get_state)
  catch
    :exit, {:noproc, _} -> {:error, :not_found}
  end

  # --- GenServer Callbacks ---

  @impl true
  def init({user_id, opts}) do
    conversation_id = Keyword.get(opts, :conversation_id)
    channel = Keyword.get(opts, :channel, "unknown")
    mode = Keyword.get(opts, :mode, @default_mode)

    # Start a per-conversation Task.Supervisor for sub-agent tasks
    {:ok, agent_supervisor} =
      Task.Supervisor.start_link(max_children: 10)

    # Hydrate recent messages from DB for conversation continuity
    hydrated_messages = hydrate_messages(conversation_id)

    state = %{
      conversation_id: conversation_id,
      user_id: user_id,
      channel: channel,
      mode: mode,
      agent_supervisor: agent_supervisor,
      messages: hydrated_messages,
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
      mode: mode,
      hydrated_messages: length(hydrated_messages)
    )

    {:ok, state}
  end

  @impl true
  def handle_call({:send_message, message}, from, state) do
    handle_call({:send_message, message, %{}}, from, state)
  end

  def handle_call({:send_message, message, message_metadata}, _from, state) do
    Logger.debug("Engine received message",
      conversation_id: state.conversation_id,
      message_length: String.length(message)
    )

    # Interrupt any still-running sub-agents from the previous turn,
    # but preserve agents awaiting approval (they need to survive across turns).
    interrupt_active_agents(state)

    # Preserve awaiting_orchestrator agents across turns so the orchestrator
    # can resume them via send_agent_update(approved: true/false).
    preserved_agents =
      Map.filter(state.dispatched_agents, fn {_id, result} ->
        result[:status] == :awaiting_orchestrator
      end)

    # Reset per-turn state for each new user message
    state =
      state
      |> Map.put(:turn_state, CircuitBreaker.new_turn_state())
      |> Map.put(:iteration_count, 0)
      |> Map.put(:dispatched_agents, preserved_agents)
      |> Map.put(:agent_tasks, %{})
      |> Map.put(:skipped, [])

    # Append user message to history
    user_msg = %{role: "user", content: message}
    state = Map.update!(state, :messages, &(&1 ++ [user_msg]))

    # Track the message index before this turn to know which messages are new
    pre_turn_message_count = length(state.messages) - 1

    # Run the orchestration loop
    case run_loop(state) do
      {:ok, response_text, final_state} ->
        # Append assistant response to history
        assistant_msg = %{role: "assistant", content: response_text}
        final_state = Map.update!(final_state, :messages, &(&1 ++ [assistant_msg]))

        # Async: persist this turn's new messages to DB (non-blocking)
        persist_turn_messages(final_state, pre_turn_message_count, message_metadata)

        # Broadcast token usage for ContextMonitor
        broadcast_token_usage(final_state)

        # Broadcast turn completion for TurnClassifier
        broadcast_turn_completed(final_state, message, response_text)

        # Async trajectory export for fine-tuning data
        enqueue_trajectory_export(final_state, message, response_text)

        {:reply, {:ok, response_text}, final_state}

      {:error, reason, final_state} ->
        Logger.error("Engine loop failed: #{inspect(reason)}",
          conversation_id: state.conversation_id
        )

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
    Logger.info("Engine terminating: #{inspect(reason)}",
      conversation_id: state.conversation_id
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
      Logger.warning("Max orchestrator iterations reached (#{state.iteration_count})",
        conversation_id: state.conversation_id
      )

      {:ok, "I reached my processing limit for this turn. Here's what I have so far.", state}
    else
      state = Map.update!(state, :iteration_count, &(&1 + 1))

      # Level 4: per-conversation rate limit check
      case Limits.check_conversation(state.conversation_state) do
        {:ok, new_conv_state} ->
          state = Map.put(state, :conversation_state, new_conv_state)
          run_loop_iteration(state)

        {:error, :limit_exceeded, details} ->
          Logger.warning("Conversation rate limit reached: #{inspect(details)}",
            conversation_id: state.conversation_id
          )

          {:ok,
           "I've reached the processing limit for this conversation window. " <>
             "Please wait a moment before sending another message.", state}
      end
    end
  end

  defp run_loop_iteration(state) do
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

                # Surface the approval reason directly so the orchestrator can
                # present it to the user without an extra get_agent_results call.
                approval_section =
                  if status == :awaiting_orchestrator and is_binary(agent_result[:reason]) do
                    "\n\n#{agent_result[:reason]}"
                  else
                    ""
                  end

                %{
                  role: "tool",
                  tool_call_id: tc.id,
                  content:
                    "Agent \"#{params.agent_id}\" finished with status: #{status}. " <>
                      "The task is complete — do NOT dispatch another agent for the same task. " <>
                      "Summarize the following result for the user.\n\n" <>
                      "Result: #{result_text}" <>
                      approval_section
                }
              end)

            # Enqueue async memory saves for completed agents (non-blocking)
            enqueue_memory_saves(state, pending_dispatches, results)

            state
            |> Map.put(:dispatched_agents, new_dispatched)
            |> Map.update!(:messages, &(&1 ++ dispatch_result_messages))

          {:error, reason} ->
            Logger.error("Agent scheduler failed: #{inspect(reason)}",
              conversation_id: state.conversation_id
            )

            # Add error messages for each dispatch, with nudge hint if available
            error_messages =
              Enum.map(pending_dispatches, fn {tc, _params} ->
                base = "Failed to dispatch agents: #{inspect(reason)}"

                %{
                  role: "tool",
                  tool_call_id: tc.id,
                  content: Nudger.format_error(base, reason)
                }
              end)

            Map.update!(state, :messages, &(&1 ++ error_messages))
        end

      {:error, :limit_exceeded, details} ->
        Logger.warning("Agent dispatch limit exceeded: #{inspect(details)}",
          conversation_id: state.conversation_id
        )

        # Add limit-exceeded messages for each dispatch tool call, with nudge hint
        base =
          "Agent dispatch limit reached (#{details.used}/#{details.max} agents this turn). " <>
            "Complete existing agents before dispatching more, or synthesize a response " <>
            "with current results."

        nudged =
          Nudger.format_error(base, :limit_exceeded, %{
            used: details.used,
            max: details.max
          })

        limit_messages =
          Enum.map(pending_dispatches, fn {tc, _params} ->
            %{
              role: "tool",
              tool_call_id: tc.id,
              content: nudged
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
    case SubAgent.execute(dispatch_params, dep_results, engine_state) do
      {:error, {:context_budget_exceeded, details}} ->
        # Convert structured error to a map result the orchestrator LLM can act on.
        # Include the per-file breakdown so the LLM can decide which files to drop.
        file_breakdown =
          (details[:files] || [])
          |> Enum.map_join("\n", fn f ->
            "  - #{f.path}: ~#{f.estimated_tokens} tokens"
          end)

        base =
          "Context files exceed token budget " <>
            "(#{details.estimated_tokens} estimated vs #{details.budget_tokens} budget, " <>
            "overage: #{details.overage_tokens} tokens).\n\n" <>
            "Per-file breakdown:\n#{file_breakdown}"

        nudged = Nudger.format_error(base, :context_budget_exceeded, details)

        %{
          status: :failed,
          result: nudged,
          tool_calls_used: 0,
          duration_ms: 0
        }

      result ->
        result
    end
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
        completion_tokens: (current[:completion_tokens] || 0) + (usage[:completion_tokens] || 0)
      }
    end)
    # Track the most recent prompt_tokens for usage-based context trimming.
    # This tells Context how many tokens the history consumed at this point.
    |> Map.put(:last_prompt_tokens, usage[:prompt_tokens])
    |> Map.put(:last_message_count, length(state.messages))
  end

  defp accumulate_usage(state, _usage), do: state

  # --- Async Memory Save ---

  # Enqueues a background Oban job for each completed sub-agent to persist the
  # full agent transcript into the memory store. Fire-and-forget: failures are
  # logged but never affect the user response.
  defp enqueue_memory_saves(state, pending_dispatches, results) do
    Enum.each(pending_dispatches, fn {_tc, params} ->
      agent_result = Map.get(results, params.agent_id, %{})
      status = agent_result[:status]

      # Only save transcripts for agents that actually completed or failed
      if status in [:completed, :failed] do
        transcript = serialize_transcript(agent_result[:messages])

        job_args = %{
          user_id: state.user_id,
          conversation_id: state.conversation_id,
          agent_id: params.agent_id,
          mission: params.mission,
          transcript: transcript,
          status: to_string(status)
        }

        case MemorySaveWorker.new(job_args) |> Oban.insert() do
          {:ok, _job} ->
            :ok

          {:error, reason} ->
            Logger.warning(
              "Failed to enqueue memory save for agent #{params.agent_id}: #{inspect(reason)}",
              conversation_id: state.conversation_id
            )
        end
      end
    end)
  end

  # Serializes the sub-agent's message list into a compact text representation
  # suitable for memory storage. Strips system prompts (large, static) and
  # keeps user/assistant/tool messages which contain the actual work.
  # Capped at @max_transcript_bytes to avoid oversized Oban job args and
  # memory_entries.content values.
  @max_transcript_bytes 50_000

  @doc false
  def serialize_transcript(nil), do: nil

  @doc false
  def serialize_transcript(messages) when is_list(messages) do
    full =
      messages
      |> Enum.reject(fn msg -> msg[:role] == "system" end)
      |> Enum.map_join("\n\n---\n\n", &format_transcript_message/1)

    if byte_size(full) > @max_transcript_bytes do
      truncated = String.slice(full, 0, @max_transcript_bytes)
      truncated <> "\n\n[transcript truncated at #{@max_transcript_bytes} bytes]"
    else
      full
    end
  end

  @doc false
  def format_transcript_message(%{role: "assistant", tool_calls: tool_calls} = msg)
      when is_list(tool_calls) and tool_calls != [] do
    # Tool call maps use atom keys when built internally (e.g., sub_agent.ex),
    # but may arrive with string keys after JSON round-tripping through the LLM
    # client. Both paths are checked for robustness.
    calls_text =
      Enum.map_join(tool_calls, "\n", fn tc ->
        name = get_in(tc, [:function, :name]) || get_in(tc, ["function", "name"]) || "unknown"
        args = get_in(tc, [:function, :arguments]) || get_in(tc, ["function", "arguments"]) || ""
        "[tool_call] #{name}: #{args}"
      end)

    case msg[:content] do
      nil -> "[assistant]\n#{calls_text}"
      "" -> "[assistant]\n#{calls_text}"
      text -> "[assistant] #{text}\n#{calls_text}"
    end
  end

  @doc false
  def format_transcript_message(%{role: role, content: content}) do
    "[#{role}] #{content}"
  end

  @doc false
  def format_transcript_message(%{role: role}) do
    "[#{role}]"
  end

  # --- PubSub Broadcasts ---

  defp broadcast_token_usage(state) do
    case state.last_prompt_tokens do
      nil ->
        :ok

      prompt_tokens when is_integer(prompt_tokens) and prompt_tokens > 0 ->
        model = ConfigLoader.model_for(:orchestrator, user_id: state.user_id)
        max_tokens = (model && model.max_context_tokens) || 200_000
        utilization = prompt_tokens / max_tokens

        Phoenix.PubSub.broadcast(
          Assistant.PubSub,
          "memory:token_usage",
          {:token_usage_updated, state.conversation_id, state.user_id, utilization}
        )

      _ ->
        :ok
    end
  end

  defp broadcast_turn_completed(state, user_message, assistant_response) do
    Phoenix.PubSub.broadcast(
      Assistant.PubSub,
      "memory:turn_completed",
      {:turn_completed,
       %{
         conversation_id: state.conversation_id,
         user_id: state.user_id,
         user_message: user_message,
         assistant_response: assistant_response
       }}
    )
  end

  # --- Interrupt Propagation ---

  # Sends an interrupt signal to all non-terminal sub-agents from the
  # previous turn. Called at the start of a new user message to stop
  # stale work. Best-effort — agents that already finished are ignored.
  defp interrupt_active_agents(state) do
    Enum.each(state.dispatched_agents, fn {agent_id, result} ->
      status = result[:status]

      # Skip awaiting_orchestrator agents — they're paused for approval and
      # need to survive across turns so the orchestrator can resume them.
      if status not in [:completed, :failed, :timeout, :skipped, :awaiting_orchestrator] do
        case SubAgent.interrupt(agent_id) do
          :ok ->
            Logger.debug("Interrupted sub-agent",
              agent_id: agent_id,
              conversation_id: state.conversation_id
            )

          {:error, :not_found} ->
            :ok
        end
      end
    end)
  end

  # --- Trajectory Export ---

  # Enqueues a background Oban job to export the current turn as JSONL.
  # Fire-and-forget: failures are logged but never affect the user response.
  defp enqueue_trajectory_export(state, user_message, assistant_response) do
    model = ConfigLoader.model_for(:orchestrator, user_id: state.user_id)
    model_id = if model, do: model.id, else: nil

    # Serialize messages for the Oban job args (must be JSON-encodable).
    # Keep only the essential fields to avoid bloating the jobs table.
    messages =
      Enum.map(state.messages, fn msg ->
        msg
        |> Map.take([:role, :content, :tool_calls, :tool_call_id])
        |> Enum.reject(fn {_k, v} -> is_nil(v) end)
        |> Map.new()
      end)

    job_args = %{
      conversation_id: state.conversation_id,
      user_id: state.user_id,
      channel: to_string(state.channel),
      mode: to_string(state.mode),
      model: model_id,
      user_message: user_message,
      assistant_response: assistant_response,
      messages: messages,
      dispatched_agents: serialize_dispatched_agents(state.dispatched_agents),
      usage: state.total_usage,
      iteration_count: state.iteration_count
    }

    case TrajectoryExportWorker.new(job_args) |> Oban.insert() do
      {:ok, _job} ->
        :ok

      {:error, reason} ->
        Logger.warning("Failed to enqueue trajectory export: #{inspect(reason)}",
          conversation_id: state.conversation_id
        )
    end
  end

  # Serializes dispatched_agents map for JSON encoding in Oban job args.
  defp serialize_dispatched_agents(agents) when is_map(agents) do
    Map.new(agents, fn {agent_id, result} ->
      {agent_id,
       %{
         status: to_string(result[:status] || "unknown"),
         result: truncate_for_export(result[:result]),
         tool_calls_used: result[:tool_calls_used] || 0,
         duration_ms: result[:duration_ms] || 0
       }}
    end)
  end

  defp serialize_dispatched_agents(_), do: %{}

  # Cap agent results at 2KB in trajectory exports to keep job args reasonable.
  defp truncate_for_export(nil), do: nil
  defp truncate_for_export(text) when is_binary(text) and byte_size(text) <= 2_000, do: text
  defp truncate_for_export(text) when is_binary(text), do: String.slice(text, 0, 2_000) <> "..."
  defp truncate_for_export(other), do: inspect(other)

  # --- Message Persistence ---

  # Hydrates recent messages from DB on engine startup for conversation continuity.
  # Returns a list of message maps in the format the LLM loop expects.
  defp hydrate_messages(nil), do: []

  defp hydrate_messages(conversation_id) do
    # Fetch the most recent N messages by querying desc, then reverse to
    # chronological order. Without this, conversations with >50 messages
    # would hydrate the oldest 50 instead of the most recent 50.
    Store.list_messages(conversation_id, limit: @hydrate_message_limit, order: :desc)
    |> Enum.reverse()
    |> Enum.map(&db_message_to_map/1)
  rescue
    error ->
      Logger.warning("Failed to hydrate messages from DB: #{inspect(error)}",
        conversation_id: conversation_id
      )

      []
  end

  # Converts a DB Message schema struct to the in-memory map format
  # used by the LLM loop. Maps DB role "tool_result" back to LLM role "tool".
  defp db_message_to_map(msg) do
    base = %{role: db_role_to_llm_role(msg.role)}

    base =
      if msg.content do
        Map.put(base, :content, msg.content)
      else
        base
      end

    base =
      if msg.tool_calls do
        Map.put(base, :tool_calls, msg.tool_calls)
      else
        base
      end

    base =
      if msg.tool_results do
        Map.put(base, :tool_call_id, msg.tool_results["tool_call_id"])
      else
        base
      end

    base
  end

  # Asynchronously persists the new messages from this turn to the DB.
  # Runs in a separate task so it doesn't block the reply to the user.
  defp persist_turn_messages(state, pre_turn_message_count, user_message_metadata) do
    conversation_id = state.conversation_id
    new_messages = Enum.drop(state.messages, pre_turn_message_count)

    if new_messages != [] and conversation_id != nil do
      Task.Supervisor.start_child(
        Assistant.Skills.TaskSupervisor,
        fn ->
          try do
            db_messages =
              new_messages
              |> Enum.with_index()
              |> Enum.map(fn {msg, idx} ->
                base = %{role: llm_role_to_db_role(msg[:role] || "assistant")}

                base =
                  if msg[:content], do: Map.put(base, :content, msg[:content]), else: base

                base =
                  if msg[:tool_calls],
                    do: Map.put(base, :tool_calls, msg[:tool_calls]),
                    else: base

                base =
                  if msg[:tool_call_id],
                    do: Map.put(base, :tool_results, %{"tool_call_id" => msg[:tool_call_id]}),
                    else: base

                base =
                  if idx == 0 and msg[:role] == "user" and
                       is_map(user_message_metadata) and
                       map_size(user_message_metadata) > 0 do
                    Map.put(base, :metadata, user_message_metadata)
                  else
                    base
                  end

                base
              end)

            case Store.batch_append_messages(conversation_id, db_messages) do
              {:ok, _inserted} ->
                Logger.debug("Persisted #{length(db_messages)} turn messages",
                  conversation_id: conversation_id
                )

              {:error, reason} ->
                Logger.warning("Failed to persist turn messages: #{inspect(reason)}",
                  conversation_id: conversation_id
                )
            end
          rescue
            error ->
              Logger.error("Persist turn messages crashed: #{Exception.message(error)}",
                conversation_id: conversation_id,
                stacktrace: Exception.format_stacktrace(__STACKTRACE__)
              )
          end
        end
      )
    end
  end

  # --- Role Mapping ---

  # The LLM loop uses "tool" for tool result messages, but the DB schema
  # (Message) uses "tool_result" to distinguish from "tool_call". These
  # helpers translate between the two conventions at the persistence boundary.

  @doc false
  def llm_role_to_db_role("tool"), do: "tool_result"
  def llm_role_to_db_role(role), do: role

  @doc false
  def db_role_to_llm_role("tool_result"), do: "tool"
  def db_role_to_llm_role(role), do: role

  defp normalize_message_metadata(nil), do: %{}
  defp normalize_message_metadata(%{} = metadata), do: metadata
  defp normalize_message_metadata(_), do: %{}

  defp via_tuple(user_id) do
    {:via, Registry, {Assistant.Orchestrator.EngineRegistry, user_id}}
  end
end
