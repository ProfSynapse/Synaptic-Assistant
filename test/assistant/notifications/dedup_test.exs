# test/assistant/notifications/dedup_test.exs
#
# Tests for the ETS-based notification deduplication module.
# Verifies duplicate detection, distinct key separation, and sweep cleanup.

defmodule Assistant.Notifications.DedupTest do
  use ExUnit.Case, async: false
  # async: false because we use a named ETS table (:notification_dedup)

  alias Assistant.Notifications.Dedup

  setup do
    # Stop the Router GenServer so it relinquishes ownership of the :notification_dedup ETS table.
    # With :protected access, only the table owner can write. By stopping the Router and
    # re-creating the table here, the test process becomes the owner for the duration of the test.
    case Process.whereis(Assistant.Notifications.Router) do
      nil -> :ok
      pid -> GenServer.stop(pid, :normal, 5000)
    end

    # Delete any existing table and create a fresh one owned by the test process.
    try do
      :ets.delete(:notification_dedup)
    rescue
      ArgumentError -> :ok
    end

    Dedup.init()

    on_exit(fn ->
      try do
        :ets.delete(:notification_dedup)
      rescue
        ArgumentError -> :ok
      end
    end)

    :ok
  end

  # ---------------------------------------------------------------
  # init/0
  # ---------------------------------------------------------------

  describe "init/0" do
    test "creates the ETS table" do
      # Table already created in setup; verify it exists
      assert :ets.info(:notification_dedup) != :undefined
    end

    test "is idempotent — calling twice does not crash" do
      assert Dedup.init() == :ok
      assert Dedup.init() == :ok
    end
  end

  # ---------------------------------------------------------------
  # duplicate?/2 and record/2
  # ---------------------------------------------------------------

  describe "duplicate?/2" do
    test "returns false when component+message has not been recorded" do
      refute Dedup.duplicate?("circuit_breaker", "Service X is degraded")
    end

    test "returns true after the same component+message is recorded" do
      Dedup.record("circuit_breaker", "Service X is degraded")
      assert Dedup.duplicate?("circuit_breaker", "Service X is degraded")
    end

    test "different messages for the same component are not duplicates" do
      Dedup.record("circuit_breaker", "Service X is degraded")
      refute Dedup.duplicate?("circuit_breaker", "Service Y is degraded")
    end

    test "same message for different components are not duplicates" do
      Dedup.record("circuit_breaker", "Service X is degraded")
      refute Dedup.duplicate?("rate_limiter", "Service X is degraded")
    end

    test "completely distinct component+message pairs are independent" do
      Dedup.record("circuit_breaker", "alert one")
      Dedup.record("rate_limiter", "alert two")

      assert Dedup.duplicate?("circuit_breaker", "alert one")
      assert Dedup.duplicate?("rate_limiter", "alert two")
      refute Dedup.duplicate?("circuit_breaker", "alert two")
      refute Dedup.duplicate?("rate_limiter", "alert one")
    end
  end

  describe "record/2" do
    test "returns :ok" do
      assert Dedup.record("comp", "msg") == :ok
    end

    test "recording the same key again updates the timestamp" do
      Dedup.record("comp", "msg")
      # Small sleep so monotonic time advances
      Process.sleep(2)
      Dedup.record("comp", "msg")

      # Should still be marked as duplicate (timestamp refreshed)
      assert Dedup.duplicate?("comp", "msg")
    end
  end

  # ---------------------------------------------------------------
  # sweep/0
  # ---------------------------------------------------------------

  describe "sweep/0" do
    test "returns 0 when no entries exist" do
      assert Dedup.sweep() == 0
    end

    test "returns 0 when all entries are fresh" do
      Dedup.record("comp1", "msg1")
      Dedup.record("comp2", "msg2")
      assert Dedup.sweep() == 0
    end

    test "removes expired entries and returns count" do
      # Manually insert an entry with a very old timestamp to simulate expiry.
      # The dedup window is 300_000 ms, so place it 400_000 ms in the past.
      old_ts = System.monotonic_time(:millisecond) - 400_000
      key = {"expired_comp", :crypto.hash(:sha256, "old msg") |> Base.encode16()}
      :ets.insert(:notification_dedup, {key, old_ts})

      # Also insert a fresh entry
      Dedup.record("fresh_comp", "fresh msg")

      swept = Dedup.sweep()
      assert swept == 1

      # Fresh entry should still exist
      assert Dedup.duplicate?("fresh_comp", "fresh msg")
    end

    test "sweep removes multiple expired entries" do
      old_ts = System.monotonic_time(:millisecond) - 400_000

      Enum.each(1..5, fn i ->
        key = {"comp_#{i}", :crypto.hash(:sha256, "msg_#{i}") |> Base.encode16()}
        :ets.insert(:notification_dedup, {key, old_ts})
      end)

      assert Dedup.sweep() == 5
    end
  end

  # ---------------------------------------------------------------
  # Edge cases
  # ---------------------------------------------------------------

  describe "edge cases" do
    test "empty strings for component and message work" do
      refute Dedup.duplicate?("", "")
      Dedup.record("", "")
      assert Dedup.duplicate?("", "")
    end

    test "unicode content is handled correctly" do
      Dedup.record("alerts", "Error: 日本語テスト")
      assert Dedup.duplicate?("alerts", "Error: 日本語テスト")
      refute Dedup.duplicate?("alerts", "Error: different")
    end

    test "very long message strings work" do
      long_msg = String.duplicate("x", 10_000)
      Dedup.record("comp", long_msg)
      assert Dedup.duplicate?("comp", long_msg)
    end
  end
end
