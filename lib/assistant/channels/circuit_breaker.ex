# lib/assistant/channels/circuit_breaker.ex — Circuit breaker for channel adapter calls.
#
# Wraps outbound adapter calls (send_reply) with failure tracking per adapter.
# After consecutive failures exceed the threshold, the circuit opens to prevent
# cascading failures, then transitions to half-open after a cooldown period to
# test recovery.
#
# Related files:
#   - lib/assistant/channels/reply_router.ex (primary consumer via call/2)
#   - lib/assistant/channels/adapter.ex (adapter behaviour being protected)
#   - lib/assistant/channels/registry.ex (adapter identification)

defmodule Assistant.Channels.CircuitBreaker do
  @moduledoc """
  Simple circuit breaker for channel adapter `send_reply` calls.

  Tracks failure counts per adapter module using an Agent. When consecutive
  failures exceed the threshold, the circuit opens and rejects calls for a
  cooldown period. After cooldown, a single test call is allowed (half-open).

  ## States

    * `:closed` — Normal operation. Failures increment the counter.
    * `:open` — Circuit tripped. All calls rejected immediately.
    * `:half_open` — Cooldown expired. One test call allowed.

  ## Configuration

    * `:circuit_breaker_threshold` — Consecutive failures before opening (default: 5)
    * `:circuit_breaker_cooldown_ms` — Cooldown period in ms before half-open (default: 30_000)

  ## Usage

      CircuitBreaker.call(MyAdapter, fn ->
        MyAdapter.send_reply(space_id, text, opts)
      end)
  """

  use Agent

  require Logger

  @default_threshold 5
  @default_cooldown_ms 30_000

  # --- State structure ---
  # %{adapter_module => %{state: :closed | :open | :half_open, failures: non_neg_integer(), opened_at: integer() | nil}}

  @doc false
  def start_link(_opts) do
    Agent.start_link(fn -> %{} end, name: __MODULE__)
  end

  @doc """
  Execute a function through the circuit breaker for the given adapter.

  Returns the function's result on success, or `{:error, :circuit_open}` if
  the circuit is open and the cooldown has not yet elapsed.

  ## Parameters

    * `adapter` — The adapter module atom (used as the circuit key)
    * `fun` — A zero-arity function to execute (typically an adapter call)
  """
  @spec call(module(), (-> term())) :: term()
  def call(adapter, fun) do
    case get_state(adapter) do
      :open ->
        if cooldown_elapsed?(adapter) do
          transition(adapter, :half_open)
          execute_and_track(adapter, fun)
        else
          {:error, :circuit_open}
        end

      :half_open ->
        execute_and_track(adapter, fun)

      :closed ->
        execute_and_track(adapter, fun)
    end
  end

  @doc """
  Returns the current circuit state for an adapter.

  Returns `:closed` if no state has been recorded for the adapter.
  """
  @spec get_state(module()) :: :closed | :open | :half_open
  def get_state(adapter) do
    Agent.get(__MODULE__, fn state ->
      case Map.get(state, adapter) do
        nil -> :closed
        %{state: s} -> s
      end
    end)
  end

  @doc """
  Resets the circuit breaker state for an adapter back to closed.

  Useful for testing or manual recovery.
  """
  @spec reset(module()) :: :ok
  def reset(adapter) do
    Agent.update(__MODULE__, fn state ->
      Map.delete(state, adapter)
    end)
  end

  # --- Private helpers ---

  defp execute_and_track(adapter, fun) do
    case fun.() do
      :ok ->
        record_success(adapter)
        :ok

      {:ok, _} = result ->
        record_success(adapter)
        result

      {:error, _} = error ->
        record_failure(adapter)
        error

      other ->
        record_success(adapter)
        other
    end
  end

  defp record_success(adapter) do
    Agent.update(__MODULE__, fn state ->
      prev = Map.get(state, adapter, %{state: :closed, failures: 0, opened_at: nil})

      if prev.state != :closed do
        Logger.warning("Circuit breaker closed for adapter",
          adapter: inspect(adapter),
          previous_state: prev.state
        )
      end

      Map.put(state, adapter, %{state: :closed, failures: 0, opened_at: nil})
    end)
  end

  defp record_failure(adapter) do
    threshold = Application.get_env(:assistant, :circuit_breaker_threshold, @default_threshold)

    Agent.update(__MODULE__, fn state ->
      prev = Map.get(state, adapter, %{state: :closed, failures: 0, opened_at: nil})
      new_failures = prev.failures + 1

      if new_failures >= threshold do
        Logger.warning("Circuit breaker opened for adapter",
          adapter: inspect(adapter),
          failures: new_failures,
          threshold: threshold
        )

        Map.put(state, adapter, %{
          state: :open,
          failures: new_failures,
          opened_at: System.monotonic_time(:millisecond)
        })
      else
        Map.put(state, adapter, %{prev | failures: new_failures})
      end
    end)
  end

  defp cooldown_elapsed?(adapter) do
    cooldown_ms =
      Application.get_env(:assistant, :circuit_breaker_cooldown_ms, @default_cooldown_ms)

    Agent.get(__MODULE__, fn state ->
      case Map.get(state, adapter) do
        %{opened_at: opened_at} when is_integer(opened_at) ->
          System.monotonic_time(:millisecond) - opened_at >= cooldown_ms

        _ ->
          true
      end
    end)
  end

  defp transition(adapter, new_state) do
    Logger.warning("Circuit breaker transitioning",
      adapter: inspect(adapter),
      new_state: new_state
    )

    Agent.update(__MODULE__, fn state ->
      prev = Map.get(state, adapter, %{state: :closed, failures: 0, opened_at: nil})
      Map.put(state, adapter, %{prev | state: new_state})
    end)
  end
end
