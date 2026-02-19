# test/assistant/workers/pending_intent_worker_test.exs — PendingIntentWorker tests.
#
# Risk Tier: HIGH — Replays user intent post-OAuth. TTL enforcement, missing args
# handling, and replay correctness are critical for user experience.
# Oban is in :inline mode for tests (config/test.exs).
#
# Note: Engine is not running in tests, so replay_intent will fail with
# {:error, _} or raise. We test args validation and TTL enforcement paths,
# not the full engine replay (that's an integration test concern).

defmodule Assistant.Workers.PendingIntentWorkerTest do
  use Assistant.DataCase, async: false

  alias Assistant.Workers.PendingIntentWorker

  # -------------------------------------------------------------------
  # perform/1 — missing args validation
  # -------------------------------------------------------------------

  describe "perform/1 missing args" do
    test "cancels job when only user_id provided" do
      job = build_job(%{"user_id" => "uid"})
      assert {:cancel, :missing_args} = PendingIntentWorker.perform(job)
    end

    test "cancels job when user_id is missing" do
      job =
        build_job(%{
          "conversation_id" => "conv-1",
          "original_message" => "hello",
          "channel" => "google_chat"
        })

      assert {:cancel, :missing_args} = PendingIntentWorker.perform(job)
    end

    test "cancels job when conversation_id is missing" do
      job =
        build_job(%{
          "user_id" => "uid",
          "original_message" => "hello",
          "channel" => "google_chat"
        })

      assert {:cancel, :missing_args} = PendingIntentWorker.perform(job)
    end

    test "cancels job when original_message is missing" do
      job =
        build_job(%{
          "user_id" => "uid",
          "conversation_id" => "conv-1",
          "channel" => "google_chat"
        })

      assert {:cancel, :missing_args} = PendingIntentWorker.perform(job)
    end

    test "cancels job when channel is missing" do
      job =
        build_job(%{
          "user_id" => "uid",
          "conversation_id" => "conv-1",
          "original_message" => "hello"
        })

      assert {:cancel, :missing_args} = PendingIntentWorker.perform(job)
    end

    test "cancels job with completely empty args" do
      job = build_job(%{})
      assert {:cancel, :missing_args} = PendingIntentWorker.perform(job)
    end
  end

  # -------------------------------------------------------------------
  # perform/1 — TTL enforcement
  # -------------------------------------------------------------------

  describe "perform/1 TTL enforcement" do
    test "cancels stale intent (> 10 minutes old)" do
      stale_time = DateTime.add(DateTime.utc_now(), -11 * 60, :second)

      job = build_job(valid_args(), inserted_at: stale_time)

      assert {:cancel, :intent_expired} = PendingIntentWorker.perform(job)
    end

    test "cancels very stale intent (> 1 hour old)" do
      very_stale = DateTime.add(DateTime.utc_now(), -3600, :second)

      job = build_job(valid_args(), inserted_at: very_stale)

      assert {:cancel, :intent_expired} = PendingIntentWorker.perform(job)
    end

    test "does not cancel fresh intent (< 10 minutes old)" do
      fresh_time = DateTime.add(DateTime.utc_now(), -5 * 60, :second)

      job = build_job(valid_args(), inserted_at: fresh_time)

      # Should NOT be cancelled as :intent_expired — it passes the TTL check
      # and proceeds to replay_intent, which will fail since Engine isn't running.
      # We catch the exit to verify it got past TTL checking.
      result =
        try do
          PendingIntentWorker.perform(job)
        catch
          :exit, _ -> :engine_exit
        end

      refute result == {:cancel, :intent_expired}
      refute result == {:cancel, :missing_args}
    end

    test "boundary: exactly 10 minutes is not stale (> not >=)" do
      # intent_stale? checks: age > @intent_ttl_seconds (600)
      # At exactly 600 seconds, age == 600, so NOT > 600, so NOT stale
      boundary_time = DateTime.add(DateTime.utc_now(), -10 * 60, :second)

      job = build_job(valid_args(), inserted_at: boundary_time)

      result =
        try do
          PendingIntentWorker.perform(job)
        catch
          :exit, _ -> :engine_exit
        end

      refute result == {:cancel, :intent_expired}
    end

    test "just over 10 minutes IS stale" do
      just_over = DateTime.add(DateTime.utc_now(), -601, :second)

      job = build_job(valid_args(), inserted_at: just_over)

      assert {:cancel, :intent_expired} = PendingIntentWorker.perform(job)
    end
  end

  # -------------------------------------------------------------------
  # perform/1 — reply_context defaulting
  # -------------------------------------------------------------------

  describe "perform/1 reply_context" do
    test "defaults reply_context to empty map when nil in args" do
      # The worker does: reply_context = args["reply_context"] || %{}
      # So nil reply_context should not cause a crash on arg extraction
      args = valid_args() |> Map.delete("reply_context")
      job = build_job(args, inserted_at: DateTime.utc_now())

      result =
        try do
          PendingIntentWorker.perform(job)
        catch
          :exit, _ -> :engine_exit
        end

      # Should not crash on missing reply_context — gets past arg validation
      refute result == {:cancel, :missing_args}
      refute result == {:cancel, :intent_expired}
    end
  end

  # -------------------------------------------------------------------
  # Helpers
  # -------------------------------------------------------------------

  defp valid_args do
    %{
      "user_id" => "uid-123",
      "conversation_id" => "conv-1",
      "original_message" => "What's on my calendar?",
      "channel" => "google_chat",
      "reply_context" => %{"space_id" => "spaces/abc"}
    }
  end

  defp build_job(args, opts \\ []) do
    inserted_at = Keyword.get(opts, :inserted_at, DateTime.utc_now())

    %Oban.Job{
      args: args,
      inserted_at: inserted_at
    }
  end
end
