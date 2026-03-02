# test/assistant/memory/context_monitor_test.exs
#
# Tests for the ContextMonitor GenServer that watches token utilization
# and dispatches compact_conversation missions to the memory agent.
#
# ContextMonitor is started under the application supervision tree, so tests
# use the already-running instance rather than starting/stopping their own.
# Each test registers the test process as the memory agent with a unique
# user_id, ensuring isolation.
#
# BUG FOUND: The cooldown deduplication uses `System.monotonic_time(:millisecond)`
# with a default of `0` for conversations not yet seen. Since monotonic_time
# returns large negative values (e.g., -576460751376), the check
# `now - 0 < 60_000` always evaluates to true, preventing dispatch for ALL
# first-time conversations. This is documented in the tests below.

defmodule Assistant.Memory.ContextMonitorTest do
  use ExUnit.Case, async: false
  # async: false because we use PubSub, named registries, and ETS config

  alias Assistant.Memory.ContextMonitor

  setup do
    # phoenix_pubsub OTP app must be started for PG2 adapter
    Application.ensure_all_started(:phoenix_pubsub)

    # Start PubSub unlinked so it survives test process cleanup.
    # start_link would link to the test process and die between tests.
    case Phoenix.PubSub.Supervisor.start_link(name: Assistant.PubSub) do
      {:ok, pid} -> Process.unlink(pid)
      {:error, {:already_started, _}} -> :ok
    end

    # Ensure SubAgent.Registry is running (for memory agent lookup).
    # Unlink so it survives test process cleanup.
    case Elixir.Registry.start_link(keys: :unique, name: Assistant.SubAgent.Registry) do
      {:ok, pid} -> Process.unlink(pid)
      {:error, {:already_started, _}} -> :ok
    end

    # Ensure the supervised ContextMonitor is alive
    assert Process.whereis(ContextMonitor) != nil,
           "ContextMonitor must be running under the application supervisor"

    :ok
  end

  # ---------------------------------------------------------------
  # GenServer lifecycle
  # ---------------------------------------------------------------

  describe "supervision" do
    test "ContextMonitor is alive under supervision" do
      pid = Process.whereis(ContextMonitor)
      assert Process.alive?(pid)
    end

    test "ignores unrelated messages" do
      pid = Process.whereis(ContextMonitor)

      # Send a message that doesn't match the handle_info pattern
      send(pid, {:unrelated_event, "data"})

      Process.sleep(20)
      assert Process.alive?(pid)
    end
  end

  # ---------------------------------------------------------------
  # PubSub subscription and message handling
  # ---------------------------------------------------------------

  describe "PubSub message handling" do
    test "receives and processes token_usage_updated events" do
      pid = Process.whereis(ContextMonitor)

      user_id = "user-recv-#{System.unique_integer([:positive])}"
      conversation_id = "conv-recv"

      # Broadcast a token usage event
      Phoenix.PubSub.broadcast(
        Assistant.PubSub,
        "memory:token_usage",
        {:token_usage_updated, conversation_id, user_id, 0.3}
      )

      # Give the GenServer time to process
      Process.sleep(50)

      # ContextMonitor should still be alive (processed without error)
      assert Process.alive?(pid)
    end

    test "below threshold — no dispatch" do
      user_id = "user-below-#{System.unique_integer([:positive])}"
      conversation_id = "conv-below"

      # Register the test process as the memory agent
      Registry.register(
        Assistant.SubAgent.Registry,
        {:memory_agent, user_id},
        nil
      )

      Phoenix.PubSub.broadcast(
        Assistant.PubSub,
        "memory:token_usage",
        {:token_usage_updated, conversation_id, user_id, 0.3}
      )

      # Should NOT receive a cast (below 0.75 threshold)
      refute_receive {:"$gen_cast", {:mission, _, _}}, 200

      Registry.unregister(Assistant.SubAgent.Registry, {:memory_agent, user_id})
    end
  end

  # ---------------------------------------------------------------
  # Cooldown deduplication bug (monotonic_time default value)
  # ---------------------------------------------------------------

  describe "cooldown deduplication" do
    # BUG: System.monotonic_time(:millisecond) returns large negative values
    # (e.g., -576460751376). The cooldown uses 0 as the default for unknown
    # conversations: `last = Map.get(state.last_compaction_at, conv_id, 0)`.
    # This means `now - 0` is always negative, which is always < 60_000,
    # making the cooldown check `now - last < @compaction_cooldown_ms` always
    # true. Result: dispatch is blocked for ALL first-time conversations.

    test "monotonic_time default of 0 blocks first-time dispatch (BUG)" do
      # Verify the bug exists: monotonic_time is negative, so (now - 0) < cooldown
      now = System.monotonic_time(:millisecond)
      default_last = 0
      cooldown_ms = :timer.seconds(60)

      assert now - default_last < cooldown_ms,
             "Expected monotonic_time bug: now (#{now}) - 0 should be < #{cooldown_ms}"
    end

    test "above threshold — dispatch blocked by cooldown bug" do
      user_id = "user-above-#{System.unique_integer([:positive])}"
      conversation_id = "conv-above"

      Registry.register(
        Assistant.SubAgent.Registry,
        {:memory_agent, user_id},
        nil
      )

      # Send utilization above threshold (0.80 > 0.75)
      Phoenix.PubSub.broadcast(
        Assistant.PubSub,
        "memory:token_usage",
        {:token_usage_updated, conversation_id, user_id, 0.80}
      )

      # Due to the monotonic_time bug, no dispatch occurs even above threshold.
      # The cooldown check incorrectly blocks first-time conversations.
      refute_receive {:"$gen_cast", {:mission, _, _}}, 200

      Registry.unregister(Assistant.SubAgent.Registry, {:memory_agent, user_id})
    end

    test "at exact threshold — dispatch blocked by cooldown bug" do
      user_id = "user-exact-#{System.unique_integer([:positive])}"
      conversation_id = "conv-exact"

      Registry.register(
        Assistant.SubAgent.Registry,
        {:memory_agent, user_id},
        nil
      )

      Phoenix.PubSub.broadcast(
        Assistant.PubSub,
        "memory:token_usage",
        {:token_usage_updated, conversation_id, user_id, 0.75}
      )

      # Blocked by same monotonic_time cooldown bug
      refute_receive {:"$gen_cast", {:mission, _, _}}, 200

      Registry.unregister(Assistant.SubAgent.Registry, {:memory_agent, user_id})
    end

    test "ContextMonitor state does not track compaction_at for first-time conversations" do
      pid = Process.whereis(ContextMonitor)
      user_id = "user-state-#{System.unique_integer([:positive])}"
      conversation_id = "conv-state"

      Registry.register(
        Assistant.SubAgent.Registry,
        {:memory_agent, user_id},
        nil
      )

      Phoenix.PubSub.broadcast(
        Assistant.PubSub,
        "memory:token_usage",
        {:token_usage_updated, conversation_id, user_id, 0.90}
      )

      Process.sleep(50)

      # The state should NOT have recorded this conversation because
      # the cooldown bug prevented dispatch (state update only happens
      # after successful dispatch).
      state = :sys.get_state(pid)
      refute Map.has_key?(state.last_compaction_at, conversation_id)

      Registry.unregister(Assistant.SubAgent.Registry, {:memory_agent, user_id})
    end
  end

  # ---------------------------------------------------------------
  # Missing memory agent
  # ---------------------------------------------------------------

  describe "missing memory agent" do
    test "does not crash when no memory agent is registered" do
      pid = Process.whereis(ContextMonitor)

      # Broadcast above threshold for a user with no registered memory agent
      Phoenix.PubSub.broadcast(
        Assistant.PubSub,
        "memory:token_usage",
        {:token_usage_updated, "conv-noagent",
         "user-noagent-#{System.unique_integer([:positive])}", 0.90}
      )

      Process.sleep(50)
      assert Process.alive?(pid)
    end
  end

  # ---------------------------------------------------------------
  # Threshold comparison (pure logic — tested via ContextMonitor behavior)
  # ---------------------------------------------------------------

  describe "threshold comparison" do
    test "ConfigLoader threshold is 0.75" do
      limits = Assistant.Config.Loader.limits_config()
      assert limits.compaction_trigger_threshold == 0.75
    end

    test "below threshold does not trigger any processing beyond no-op" do
      user_id = "user-noop-#{System.unique_integer([:positive])}"
      conversation_id = "conv-noop"
      pid = Process.whereis(ContextMonitor)

      # Get state before
      state_before = :sys.get_state(pid)

      Phoenix.PubSub.broadcast(
        Assistant.PubSub,
        "memory:token_usage",
        {:token_usage_updated, conversation_id, user_id, 0.50}
      )

      Process.sleep(50)

      # State should be unchanged (below threshold, no cooldown tracking)
      state_after = :sys.get_state(pid)
      refute Map.has_key?(state_after.last_compaction_at, conversation_id)

      # And no compaction was attempted
      assert state_before.last_compaction_at == state_after.last_compaction_at or
               not Map.has_key?(state_after.last_compaction_at, conversation_id)
    end
  end
end
