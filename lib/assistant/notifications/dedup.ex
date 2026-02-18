# lib/assistant/notifications/dedup.ex — ETS-based notification deduplication.
#
# Prevents the same alert from being sent repeatedly within a configurable
# time window. Used by Router to suppress duplicate notifications for the
# same component + message combination.

defmodule Assistant.Notifications.Dedup do
  @moduledoc """
  ETS-based deduplication for notifications.

  Tracks recently dispatched alerts by a SHA-256 hash of
  `{component, message}`. Entries older than the dedup window
  are swept periodically by the Router GenServer.
  """

  @table :notification_dedup
  @dedup_window_ms 300_000

  @doc """
  Creates the ETS table. Safe to call multiple times — silently
  returns `:ok` if the table already exists.
  """
  @spec init() :: :ok
  def init do
    :ets.new(@table, [:named_table, :protected, :set])
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc """
  Returns `true` if this component + message combination was seen
  within the dedup window.
  """
  @spec duplicate?(String.t(), String.t()) :: boolean()
  def duplicate?(component, message) do
    key = build_key(component, message)
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(@table, key) do
      [{^key, timestamp}] -> now - timestamp < @dedup_window_ms
      [] -> false
    end
  end

  @doc """
  Records a component + message combination with the current timestamp.
  """
  @spec record(String.t(), String.t()) :: :ok
  def record(component, message) do
    key = build_key(component, message)
    :ets.insert(@table, {key, System.monotonic_time(:millisecond)})
    :ok
  end

  @doc """
  Removes entries older than the dedup window.
  Called periodically by the Router.
  """
  @spec sweep() :: non_neg_integer()
  def sweep do
    cutoff = System.monotonic_time(:millisecond) - @dedup_window_ms

    # Select keys where timestamp < cutoff, then delete them
    expired =
      :ets.select(@table, [
        {{:"$1", :"$2"}, [{:<, :"$2", cutoff}], [:"$1"]}
      ])

    Enum.each(expired, &:ets.delete(@table, &1))
    length(expired)
  end

  # Builds a dedup key from component + SHA-256 of message.
  defp build_key(component, message) do
    hash = :crypto.hash(:sha256, message) |> Base.encode16()
    {component, hash}
  end
end
