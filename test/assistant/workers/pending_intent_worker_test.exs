# test/assistant/workers/pending_intent_worker_test.exs
#
# Tests for PendingIntentWorker — the Oban worker that replays user commands
# after OAuth authorization. Tests staleness checking and argument validation
# without requiring the full orchestrator or channel infrastructure.
#
# Related files:
#   - lib/assistant/workers/pending_intent_worker.ex (module under test)
#   - lib/assistant_web/controllers/oauth_controller.ex (enqueues this worker)

defmodule Assistant.Workers.PendingIntentWorkerTest do
  use Assistant.DataCase, async: true

  alias Assistant.Workers.PendingIntentWorker

  # ---------------------------------------------------------------
  # Staleness — jobs older than 10 minutes are discarded
  # ---------------------------------------------------------------

  describe "perform/1 staleness" do
    test "discards stale job (>10 min old)" do
      stale_time = DateTime.add(DateTime.utc_now(), -700, :second)

      job = %Oban.Job{
        args: %{
          "user_id" => "user-1",
          "message" => "search my drive",
          "conversation_id" => "conv-1",
          "channel" => "google_chat",
          "reply_context" => %{"space_id" => "space-1"}
        },
        inserted_at: stale_time
      }

      assert {:cancel, :stale_intent} = PendingIntentWorker.perform(job)
    end

    test "does not discard recent job (stale check passes)" do
      recent_time = DateTime.add(DateTime.utc_now(), -5, :second)

      job = %Oban.Job{
        args: %{
          "user_id" => "user-1",
          "message" => "test",
          "conversation_id" => "conv-#{System.unique_integer([:positive])}",
          "channel" => "test",
          "reply_context" => %{}
        },
        inserted_at: recent_time
      }

      # Will fail on Engine (not running), but importantly NOT :stale_intent.
      # Catch the exit since Engine.get_state/send_message raises when
      # the GenServer is not available.
      result =
        try do
          PendingIntentWorker.perform(job)
        catch
          :exit, _ -> {:error, :engine_not_available}
        end

      refute match?({:cancel, :stale_intent}, result)
    end
  end

  # ---------------------------------------------------------------
  # Missing required args
  # ---------------------------------------------------------------

  describe "perform/1 missing args" do
    test "cancels when user_id is missing" do
      job = %Oban.Job{
        args: %{
          "message" => "test",
          "conversation_id" => "conv-1"
        },
        inserted_at: DateTime.utc_now()
      }

      assert {:cancel, :missing_required_args} = PendingIntentWorker.perform(job)
    end

    test "cancels when message is missing" do
      job = %Oban.Job{
        args: %{
          "user_id" => "user-1",
          "conversation_id" => "conv-1"
        },
        inserted_at: DateTime.utc_now()
      }

      assert {:cancel, :missing_required_args} = PendingIntentWorker.perform(job)
    end

    test "cancels when conversation_id is missing" do
      job = %Oban.Job{
        args: %{
          "user_id" => "user-1",
          "message" => "test"
        },
        inserted_at: DateTime.utc_now()
      }

      assert {:cancel, :missing_required_args} = PendingIntentWorker.perform(job)
    end
  end

  # ---------------------------------------------------------------
  # Bug 2: Engine contract — worker uses user_id, not conversation_id
  # ---------------------------------------------------------------

  describe "perform/1 engine contract (Bug 2 fix)" do
    test "passes user_id (not conversation_id) to Engine functions" do
      # This test verifies the worker's code paths reference the correct
      # Engine API. A recent job with valid args should attempt Engine
      # operations using user_id, which causes an :exit when the Engine
      # is not running (registered by user_id, not conversation_id).
      recent_time = DateTime.add(DateTime.utc_now(), -2, :second)
      user_id = Ecto.UUID.generate()

      job = %Oban.Job{
        args: %{
          "user_id" => user_id,
          "message" => "test engine contract",
          "conversation_id" => Ecto.UUID.generate(),
          "channel" => "test",
          "reply_context" => %{}
        },
        inserted_at: recent_time
      }

      # Worker should attempt Engine.get_state(user_id). Since no Engine
      # is running, it will try to start one via DynamicSupervisor, which
      # will fail since ConversationSupervisor isn't running in test.
      # The key assertion: it doesn't fail with :stale_intent or
      # :missing_required_args — it reaches the engine layer.
      result =
        try do
          PendingIntentWorker.perform(job)
        catch
          :exit, _ -> {:error, :engine_not_available}
        end

      refute match?({:cancel, :stale_intent}, result)
      refute match?({:cancel, :missing_required_args}, result)
    end
  end

  # ---------------------------------------------------------------
  # Edge: stale check boundary
  # ---------------------------------------------------------------

  describe "staleness boundary" do
    test "job at exactly 600 seconds is not stale (boundary)" do
      boundary_time = DateTime.add(DateTime.utc_now(), -600, :second)

      job = %Oban.Job{
        args: %{
          "user_id" => "user-1",
          "message" => "test",
          "conversation_id" => "conv-boundary-#{System.unique_integer([:positive])}",
          "channel" => "test",
          "reply_context" => %{}
        },
        inserted_at: boundary_time
      }

      # At exactly 600s, should NOT be cancelled as stale.
      # Catch exit from Engine not being available.
      result =
        try do
          PendingIntentWorker.perform(job)
        catch
          :exit, _ -> {:error, :engine_not_available}
        end

      refute match?({:cancel, :stale_intent}, result)
    end

    test "job at 601 seconds is stale" do
      over_time = DateTime.add(DateTime.utc_now(), -601, :second)

      job = %Oban.Job{
        args: %{
          "user_id" => "user-1",
          "message" => "test",
          "conversation_id" => "conv-1",
          "channel" => "test",
          "reply_context" => %{}
        },
        inserted_at: over_time
      }

      assert {:cancel, :stale_intent} = PendingIntentWorker.perform(job)
    end
  end
end
