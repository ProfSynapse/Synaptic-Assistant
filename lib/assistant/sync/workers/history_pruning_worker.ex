# lib/assistant/sync/workers/history_pruning_worker.ex — Retention-based pruning of sync history.
#
# Oban cron worker that deletes sync_history entries older than a configurable
# retention period (default 90 days). Runs daily to keep the audit log bounded.
#
# Related files:
#   - lib/assistant/schemas/sync_history_entry.ex (rows being pruned)
#   - lib/assistant/sync/state_store.ex (query context)
#   - config/config.exs (Oban cron schedule)

defmodule Assistant.Sync.Workers.HistoryPruningWorker do
  @moduledoc """
  Oban cron worker that prunes old sync history entries.

  Deletes entries from the sync_history table that are older than the
  configured retention period. Defaults to 90 days.

  ## Configuration

      config :assistant, :sync_history_retention_days, 90

  ## Queue

  Runs in the `:sync` queue with `max_attempts: 1` (pruning is idempotent).
  """

  use Oban.Worker, queue: :sync, max_attempts: 1

  import Ecto.Query

  alias Assistant.Repo
  alias Assistant.Schemas.SyncHistoryEntry

  require Logger

  @default_retention_days 90

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    retention_days =
      Application.get_env(:assistant, :sync_history_retention_days, @default_retention_days)

    cutoff = DateTime.add(DateTime.utc_now(), -retention_days, :day)

    {count, _} =
      SyncHistoryEntry
      |> where([h], h.inserted_at < ^cutoff)
      |> Repo.delete_all()

    if count > 0 do
      Logger.info("HistoryPruningWorker: pruned #{count} entries older than #{retention_days} days")
    end

    :ok
  end
end
