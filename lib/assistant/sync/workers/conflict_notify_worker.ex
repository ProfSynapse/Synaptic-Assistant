# lib/assistant/sync/workers/conflict_notify_worker.ex — Oban worker for conflict notifications.
#
# Enqueued by SyncPollWorker when a file conflict is detected. Loads the
# synced file record and logs a prominent notification. In v1, this is
# log-only; future versions may send chat notifications via the user's
# active channel.
#
# Related files:
#   - lib/assistant/sync/workers/sync_poll_worker.ex (enqueues this worker)
#   - lib/assistant/sync/state_store.ex (loads synced file records)

defmodule Assistant.Sync.Workers.ConflictNotifyWorker do
  @moduledoc """
  Oban worker that sends conflict notifications when sync detects a conflict.

  Accepts a job with `synced_file_id` and `user_id` args. Loads the synced
  file record, formats a human-readable notification, and logs it prominently.

  ## Future Enhancements

  Future versions will deliver notifications via the user's preferred
  channel (chat, email, etc.) using `Assistant.Notifications.Router`.
  For v1, we log at `:warning` level so conflicts are visible in logs.

  ## Queue

  Runs in the `:sync` queue with `max_attempts: 3`.
  """

  use Oban.Worker, queue: :sync, max_attempts: 3

  alias Assistant.Sync.StateStore

  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"synced_file_id" => synced_file_id, "user_id" => user_id}}) do
    case StateStore.get_synced_file_by_id(synced_file_id) do
      nil ->
        Logger.info("ConflictNotifyWorker: synced file #{synced_file_id} no longer exists, skipping")
        :ok

      synced_file ->
        notify_conflict(user_id, synced_file)
        :ok
    end
  end

  def perform(%Oban.Job{args: args}) do
    Logger.warning("ConflictNotifyWorker: invalid args: #{inspect(args)}")
    :ok
  end

  defp notify_conflict(user_id, synced_file) do
    message = """
    [SYNC CONFLICT] File: #{synced_file.drive_file_name}
    User: #{user_id}
    Drive File ID: #{synced_file.drive_file_id}
    Local Path: #{synced_file.local_path}
    Status: #{synced_file.sync_status}
    Error: #{synced_file.sync_error}

    Both the local copy and remote Drive file have been modified since the last sync.
    A conflict copy has been saved locally. Manual resolution is required.
    """

    Logger.warning(message)

    # v1: Log only. Future: send via Notifications.Router to user's active channel.
    # Example future integration:
    #   Assistant.Notifications.Router.dispatch(%{
    #     user_id: user_id,
    #     type: :sync_conflict,
    #     title: "Sync Conflict: #{synced_file.drive_file_name}",
    #     body: message
    #   })

    :ok
  end
end
