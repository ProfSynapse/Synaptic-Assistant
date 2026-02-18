# test/assistant/resilience/rate_limiter_test.exs
#
# Tests for the sliding window rate limiter.
# Pure functional module — no GenServer, fully deterministic.

defmodule Assistant.Resilience.RateLimiterTest do
  use ExUnit.Case, async: true

  alias Assistant.Resilience.RateLimiter

  describe "new/1" do
    test "creates state with specified limits" do
      state = RateLimiter.new(max_calls: 10, window_ms: 60_000)
      assert state.max_calls == 10
      assert state.window_ms == 60_000
      assert state.timestamps == []
    end

    test "raises on missing required options" do
      assert_raise KeyError, fn -> RateLimiter.new(max_calls: 10) end
      assert_raise KeyError, fn -> RateLimiter.new(window_ms: 1000) end
    end
  end

  describe "check/2" do
    test "allows calls within limit" do
      state = RateLimiter.new(max_calls: 3, window_ms: 60_000)

      assert {:ok, state} = RateLimiter.check(state)
      assert {:ok, state} = RateLimiter.check(state)
      assert {:ok, _state} = RateLimiter.check(state)
    end

    test "rejects calls exceeding limit" do
      state = RateLimiter.new(max_calls: 2, window_ms: 60_000)

      assert {:ok, state} = RateLimiter.check(state)
      assert {:ok, state} = RateLimiter.check(state)
      assert {:error, details} = RateLimiter.check(state)

      assert details.current_count == 2
      assert details.requested == 1
      assert details.max_calls == 2
    end

    test "multi-count check works" do
      state = RateLimiter.new(max_calls: 5, window_ms: 60_000)

      assert {:ok, state} = RateLimiter.check(state, 3)
      assert {:ok, _state} = RateLimiter.check(state, 2)
    end

    test "multi-count check rejects when exceeding limit" do
      state = RateLimiter.new(max_calls: 5, window_ms: 60_000)

      assert {:ok, state} = RateLimiter.check(state, 3)
      assert {:error, details} = RateLimiter.check(state, 4)
      assert details.current_count == 3
      assert details.requested == 4
    end

    test "expired timestamps are pruned" do
      # Use a very short window so entries expire quickly
      state = RateLimiter.new(max_calls: 2, window_ms: 50)

      assert {:ok, state} = RateLimiter.check(state)
      assert {:ok, state} = RateLimiter.check(state)
      # At limit
      assert {:error, _} = RateLimiter.check(state)

      # Wait for window to expire
      Process.sleep(60)

      # Should be allowed again after expiry
      assert {:ok, _state} = RateLimiter.check(state)
    end
  end

  describe "current_count/1" do
    test "returns zero for fresh state" do
      state = RateLimiter.new(max_calls: 5, window_ms: 60_000)
      assert RateLimiter.current_count(state) == 0
    end

    test "returns correct count after checks" do
      state = RateLimiter.new(max_calls: 5, window_ms: 60_000)
      {:ok, state} = RateLimiter.check(state)
      {:ok, state} = RateLimiter.check(state, 2)
      assert RateLimiter.current_count(state) == 3
    end
  end

  describe "reset/1" do
    test "clears all timestamps" do
      state = RateLimiter.new(max_calls: 2, window_ms: 60_000)
      {:ok, state} = RateLimiter.check(state)
      {:ok, state} = RateLimiter.check(state)

      reset_state = RateLimiter.reset(state)
      assert reset_state.timestamps == []
      assert {:ok, _} = RateLimiter.check(reset_state)
    end
  end

  describe "prune/1" do
    test "removes expired timestamps" do
      state = RateLimiter.new(max_calls: 10, window_ms: 50)
      {:ok, state} = RateLimiter.check(state, 5)

      Process.sleep(60)

      pruned = RateLimiter.prune(state)
      assert pruned.timestamps == []
    end
  end
end
