# lib/assistant/sync/workers/sync_poll_worker.ex — Oban cron worker for Drive sync polling.
#
# Periodically polls the Google Drive Changes API for each active sync user,
# detects changes within configured scopes, converts updated files to local
# formats, and manages conflicts. Individual file failures do not abort the
# entire poll cycle.
#
# Related files:
#   - lib/assistant/sync/state_store.ex (cursor + file state persistence)
#   - lib/assistant/sync/converter.ex (Drive → local format conversion)
#   - lib/assistant/sync/file_manager.ex (encrypted local file I/O)
#   - lib/assistant/sync/change_detector.ex (conflict detection)
#   - lib/assistant/sync/workers/conflict_notify_worker.ex (conflict alerts)
#   - lib/assistant/integrations/google/drive/changes.ex (Changes API client)
#   - lib/assistant/integrations/google/auth.ex (per-user OAuth tokens)
#   - config/config.exs (Oban cron schedule)

defmodule Assistant.Sync.Workers.SyncPollWorker do
  @moduledoc """
  Oban cron worker that polls the Drive Changes API for each active sync user.

  Runs on a configurable schedule (default: every 60 seconds via Oban Cron).
  For each user with active sync cursors:

    1. Fetch changes since the last poll token
    2. Filter to files within the user's configured sync scopes
    3. Detect conflicts between local and remote changes
    4. Convert and write updated files (or create conflict copies)
    5. Update the cursor for the next poll cycle
    6. Record audit history for each operation

  Individual file failures are logged and recorded but do not abort the
  full poll cycle — other files continue processing.

  ## Queue

  Runs in the `:sync` queue with `max_attempts: 3`.
  """

  use Oban.Worker, queue: :sync, max_attempts: 3

  alias Assistant.Integrations.Google.Auth
  alias Assistant.Integrations.Google.Drive.Changes
  alias Assistant.Sync.StateStore

  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"user_id" => user_id}}) do
    # Per-user job dispatched by the cron dispatcher below
    poll_user(user_id)
    :ok
  end

  def perform(%Oban.Job{args: _args}) do
    # Cron dispatcher: enqueue individual per-user jobs for parallel execution
    users_with_cursors = list_active_sync_users()

    Enum.each(users_with_cursors, fn user_id ->
      %{user_id: user_id}
      |> __MODULE__.new(queue: :sync)
      |> Oban.insert()
    end)

    :ok
  end

  # -- Per-User Poll --

  defp poll_user(user_id) do
    case Auth.user_token(user_id) do
      {:ok, access_token} ->
        cursors = StateStore.list_cursors(user_id)

        Enum.each(cursors, fn cursor ->
          poll_cursor(user_id, access_token, cursor)
        end)

      {:error, reason} ->
        Logger.warning("SyncPollWorker: skipping user #{user_id}, auth error: #{inspect(reason)}")
    end
  end

  defp poll_cursor(user_id, access_token, cursor) do
    drive_opts = if cursor.drive_id, do: [drive_id: cursor.drive_id], else: []

    case Changes.list_all_changes(access_token, cursor.start_page_token, drive_opts) do
      {:ok, %{changes: changes, new_start_page_token: new_token}} ->
        enqueue_changes(user_id, cursor.drive_id, changes)
        update_cursor(user_id, cursor, new_token)

      {:error, reason} ->
        Logger.error("SyncPollWorker: Changes API failed for user #{user_id}",
          drive_id: cursor.drive_id,
          reason: inspect(reason)
        )
    end
  end

  # -- Change Processing --

  defp enqueue_changes(user_id, drive_id, changes) do
    jobs =
      changes
      |> Enum.filter(fn change ->
        parent_folder = first_parent(change)
        in_scope?(user_id, drive_id, parent_folder)
      end)
      |> Enum.map(fn change ->
        action =
          if change[:removed] == true or change[:trashed] == true, do: "delete", else: "upsert"

        %{
          action: action,
          user_id: user_id,
          drive_id: drive_id,
          drive_file_id: change.file_id,
          change: change
        }
        |> Assistant.Sync.Workers.FileSyncWorker.new()
      end)

    if length(jobs) > 0 do
      Oban.insert_all(jobs)
    end
  end

  # -- Helpers --

  defp list_active_sync_users do
    # Query distinct user_ids from sync_cursors table
    import Ecto.Query

    Assistant.Schemas.SyncCursor
    |> select([c], c.user_id)
    |> distinct(true)
    |> Assistant.Repo.all()
  end

  defp in_scope?(user_id, drive_id, parent_folder) do
    StateStore.folder_in_scope?(user_id, drive_id, parent_folder) != nil
  end

  defp first_parent(change) do
    case change[:parents] do
      [parent | _] -> parent
      _ -> nil
    end
  end

  defp update_cursor(user_id, cursor, new_token) do
    StateStore.upsert_cursor(%{
      user_id: user_id,
      drive_id: cursor.drive_id,
      start_page_token: new_token,
      last_poll_at: DateTime.utc_now()
    })
  end
end
