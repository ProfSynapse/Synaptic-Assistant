# lib/assistant/memory/context_monitor.ex — Token utilization monitor.
#
# GenServer that subscribes to PubSub token usage events from the orchestrator
# engine. When context utilization crosses the compaction threshold, dispatches
# a compact_conversation mission to the user's memory agent (looked up via
# Registry). Tracks per-conversation compaction timestamps to avoid duplicate
# triggers while a compaction is already in progress.
#
# Related files:
#   - lib/assistant/orchestrator/engine.ex (publishes :token_usage_updated events)
#   - lib/assistant/memory/agent.ex (receives compact_conversation dispatch)
#   - lib/assistant/config/loader.ex (compaction_trigger_threshold from limits)
#   - lib/assistant/application.ex (supervision tree)

defmodule Assistant.Memory.ContextMonitor do
  @moduledoc """
  Watches conversation token utilization and triggers compaction.

  Subscribes to PubSub topic `"memory:token_usage"`. When utilization reaches
  the configured threshold
  (`limits.compaction_trigger_threshold`), dispatches a `compact_conversation`
  mission to the user's memory agent.

  ## Deduplication

  Tracks `last_compaction_at` per conversation to avoid re-triggering
  compaction if one is already in progress. A 60-second cooldown prevents
  rapid-fire dispatches.
  """

  use GenServer

  require Logger

  alias Assistant.Config.Loader, as: ConfigLoader

  @compaction_cooldown_ms :timer.seconds(60)

  # --- Client API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  # --- GenServer Callbacks ---

  @impl true
  def init(_opts) do
    Phoenix.PubSub.subscribe(Assistant.PubSub, "memory:token_usage")
    {:ok, %{last_compaction_at: %{}}}
  end

  @impl true
  def handle_info(
        {:token_usage_updated, conversation_id, user_id, utilization},
        state
      ) do
    threshold = ConfigLoader.limits_config().compaction_trigger_threshold

    state =
      if utilization >= threshold do
        maybe_dispatch_compaction(conversation_id, user_id, utilization, state)
      else
        state
      end

    {:noreply, state}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # --- Internal ---

  defp maybe_dispatch_compaction(conversation_id, user_id, utilization, state) do
    now = System.monotonic_time(:millisecond)
    last = Map.get(state.last_compaction_at, conversation_id, 0)

    if now - last < @compaction_cooldown_ms do
      Logger.debug("Compaction cooldown active, skipping",
        conversation_id: conversation_id,
        cooldown_remaining_ms: @compaction_cooldown_ms - (now - last)
      )

      state
    else
      dispatch_to_memory_agent(conversation_id, user_id, utilization)

      put_in(state, [:last_compaction_at, conversation_id], now)
    end
  end

  defp dispatch_to_memory_agent(conversation_id, user_id, utilization) do
    case Registry.lookup(Assistant.SubAgent.Registry, {:memory_agent, user_id}) do
      [{pid, _value}] ->
        Logger.info("Dispatching compact_conversation to memory agent",
          conversation_id: conversation_id,
          user_id: user_id,
          utilization: Float.round(utilization, 3)
        )

        GenServer.cast(pid, {:mission, :compact_conversation, %{
          conversation_id: conversation_id,
          user_id: user_id,
          trigger: :context_utilization,
          utilization: utilization
        }})

      [] ->
        Logger.warning("Memory agent not found for user, skipping compaction",
          user_id: user_id,
          conversation_id: conversation_id
        )
    end
  end
end
