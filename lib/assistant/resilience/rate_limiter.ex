# lib/assistant/resilience/rate_limiter.ex — Sliding window rate limiter.
#
# Provides a purely functional sliding window rate limiter for per-conversation
# limits. Tracks timestamps of calls and prunes expired entries on each check.
# No GenServer needed — state is threaded through the caller (typically the
# Orchestrator Engine's LoopState).
#
# Used by Assistant.Resilience.CircuitBreaker for Level 4 (per-conversation)
# limits.

defmodule Assistant.Resilience.RateLimiter do
  @moduledoc """
  Sliding window rate limiter using a functional (stateless) design.

  Tracks call timestamps in a list and prunes expired entries on each check.
  Callers are responsible for threading the state map through their own state
  management (e.g., GenServer state, function arguments).

  ## Example

      state = RateLimiter.new(max_calls: 10, window_ms: 60_000)

      case RateLimiter.check(state) do
        {:ok, new_state} ->
          # Call allowed, use new_state going forward
          do_work()

        {:error, details} ->
          # Rate limited
          {:error, :rate_limited}
      end
  """

  @type t :: %{
          max_calls: pos_integer(),
          window_ms: pos_integer(),
          timestamps: [integer()]
        }

  @doc """
  Creates a new rate limiter state.

  ## Options
    - `:max_calls` — maximum calls allowed within the window (required)
    - `:window_ms` — sliding window duration in milliseconds (required)
  """
  @spec new(keyword()) :: t()
  def new(opts) do
    %{
      max_calls: Keyword.fetch!(opts, :max_calls),
      window_ms: Keyword.fetch!(opts, :window_ms),
      timestamps: []
    }
  end

  @doc """
  Checks whether `count` calls are allowed within the sliding window.

  Prunes expired timestamps, then checks if adding `count` new calls would
  exceed the limit.

  Returns `{:ok, updated_state}` with the new timestamps recorded, or
  `{:error, details}` with information about the current limit state.

  ## Parameters
    - `state` — rate limiter state from `new/1`
    - `count` — number of calls to record (default: 1)
  """
  @spec check(t(), pos_integer()) :: {:ok, t()} | {:error, map()}
  def check(state, count \\ 1) do
    now = monotonic_now()
    cutoff = now - state.window_ms

    # Prune expired timestamps
    active = Enum.filter(state.timestamps, fn ts -> ts > cutoff end)
    current_count = length(active)

    if current_count + count > state.max_calls do
      {:error,
       %{
         current_count: current_count,
         requested: count,
         max_calls: state.max_calls,
         window_ms: state.window_ms
       }}
    else
      new_timestamps = List.duplicate(now, count) ++ active
      {:ok, %{state | timestamps: new_timestamps}}
    end
  end

  @doc """
  Returns the number of calls currently within the active window.

  Does NOT modify state (no pruning side effect). For an accurate count
  that also prunes, use `prune/1` first.
  """
  @spec current_count(t()) :: non_neg_integer()
  def current_count(state) do
    now = monotonic_now()
    cutoff = now - state.window_ms

    state.timestamps
    |> Enum.count(fn ts -> ts > cutoff end)
  end

  @doc """
  Prunes expired timestamps and returns the cleaned state.

  Useful for periodic cleanup without recording a new call.
  """
  @spec prune(t()) :: t()
  def prune(state) do
    now = monotonic_now()
    cutoff = now - state.window_ms

    active = Enum.filter(state.timestamps, fn ts -> ts > cutoff end)
    %{state | timestamps: active}
  end

  @doc """
  Resets the rate limiter, clearing all recorded timestamps.
  """
  @spec reset(t()) :: t()
  def reset(state) do
    %{state | timestamps: []}
  end

  # Uses monotonic time to avoid clock skew issues.
  defp monotonic_now do
    System.monotonic_time(:millisecond)
  end
end
