# lib/assistant/sync/helpers.ex — Shared helper functions for the sync engine.
#
# Provides common utility functions used across multiple sync modules,
# extracted to avoid duplication. All functions are pure with no side effects.
#
# Related files:
#   - lib/assistant/sync/workers/sync_poll_worker.ex (consumer)
#   - lib/assistant/sync/change_detector.ex (consumer)

defmodule Assistant.Sync.Helpers do
  @moduledoc false

  @doc """
  Parse a time value that may be a DateTime, an ISO 8601 string, or nil.

  Returns a %DateTime{} or nil. Used by the sync engine to normalize
  timestamps from the Drive Changes API.
  """
  @spec parse_time(DateTime.t() | String.t() | nil) :: DateTime.t() | nil
  def parse_time(nil), do: nil
  def parse_time(%DateTime{} = dt), do: dt

  def parse_time(time_string) when is_binary(time_string) do
    case DateTime.from_iso8601(time_string) do
      {:ok, dt, _offset} -> dt
      {:error, _} -> nil
    end
  end

  def parse_time(_), do: nil
end
