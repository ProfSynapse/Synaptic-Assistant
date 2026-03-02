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
  alias Assistant.Sync.{ChangeDetector, Converter, FileManager, StateStore}

  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    users_with_cursors = list_active_sync_users()

    Enum.each(users_with_cursors, fn user_id ->
      poll_user(user_id)
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
        process_changes(user_id, access_token, cursor.drive_id, changes)
        update_cursor(user_id, cursor, new_token)

      {:error, reason} ->
        Logger.error("SyncPollWorker: Changes API failed for user #{user_id}",
          drive_id: cursor.drive_id,
          reason: inspect(reason)
        )
    end
  end

  # -- Change Processing --

  defp process_changes(user_id, access_token, drive_id, changes) do
    Enum.each(changes, fn change ->
      process_single_change(user_id, access_token, drive_id, change)
    end)
  end

  defp process_single_change(user_id, access_token, drive_id, change) do
    # Check if the file's parent folder is within user's sync scopes
    parent_folder = first_parent(change)

    unless in_scope?(user_id, drive_id, parent_folder) do
      # File is not in any sync scope — skip
      :ok
    else
      try do
        handle_change(user_id, access_token, drive_id, change)
      rescue
        e ->
          Logger.error("SyncPollWorker: failed processing file #{change.file_id}",
            user_id: user_id,
            error: Exception.message(e)
          )

          record_error(user_id, change, Exception.message(e))
      end
    end
  end

  defp handle_change(user_id, access_token, drive_id, change) do
    synced_file = StateStore.get_synced_file(user_id, change.file_id)

    cond do
      # File was removed or trashed
      change[:removed] == true or change[:trashed] == true ->
        handle_trash(user_id, synced_file, change)

      # File was untrashed (restored)
      synced_file && synced_file.sync_status == "error" && not (change[:trashed] || false) ->
        handle_update(user_id, access_token, drive_id, synced_file, change)

      # Normal change — detect conflict
      true ->
        case ChangeDetector.detect_conflict(synced_file, change) do
          :no_conflict ->
            :ok

          :remote_updated ->
            handle_update(user_id, access_token, drive_id, synced_file, change)

          :conflict ->
            handle_conflict(user_id, access_token, drive_id, synced_file, change)
        end
    end
  end

  # -- Update Handler --

  defp handle_update(user_id, access_token, drive_id, synced_file, change) do
    with {:ok, {content, format}} <- Converter.convert(access_token, change.file_id, change.mime_type),
         relative_path <- build_relative_path(change, format),
         {:ok, _full_path} <- FileManager.write_file(user_id, relative_path, content) do
      content_checksum = FileManager.checksum(content)
      now = DateTime.utc_now()

      file_attrs = %{
        user_id: user_id,
        drive_file_id: change.file_id,
        drive_file_name: change.name,
        drive_mime_type: change.mime_type,
        local_path: relative_path,
        local_format: format,
        remote_modified_at: parse_time(change.modified_time),
        local_modified_at: now,
        remote_checksum: content_checksum,
        local_checksum: content_checksum,
        sync_status: "synced",
        last_synced_at: now,
        sync_error: nil,
        drive_id: drive_id
      }

      result =
        if synced_file do
          StateStore.update_synced_file(synced_file, file_attrs)
        else
          StateStore.create_synced_file(file_attrs)
        end

      case result do
        {:ok, saved_file} ->
          operation = if synced_file, do: "download", else: "download"

          StateStore.create_history_entry(%{
            synced_file_id: saved_file.id,
            operation: operation,
            details: %{"message" => "Synced #{change.name} (#{format})"}
          })

        {:error, changeset} ->
          Logger.error("SyncPollWorker: failed to save synced file",
            file_id: change.file_id,
            errors: inspect(changeset.errors)
          )
      end
    else
      {:error, reason} ->
        Logger.error("SyncPollWorker: update failed for #{change.file_id}",
          reason: inspect(reason)
        )

        if synced_file do
          StateStore.update_synced_file(synced_file, %{
            sync_status: "error",
            sync_error: "Update failed: #{inspect(reason)}"
          })
        end
    end
  end

  # -- Conflict Handler --

  defp handle_conflict(user_id, access_token, _drive_id, synced_file, change) do
    # Write the remote version as a conflict copy
    with {:ok, {content, _format}} <- Converter.convert(access_token, change.file_id, change.mime_type) do
      conflict_path = ChangeDetector.generate_conflict_path(synced_file.local_path)

      case FileManager.write_file(user_id, conflict_path, content) do
        {:ok, _full_path} ->
          # Mark the original as conflicted
          StateStore.update_synced_file(synced_file, %{
            sync_status: "conflict",
            sync_error: "Both local and remote modified. Conflict copy at: #{conflict_path}"
          })

          StateStore.create_history_entry(%{
            synced_file_id: synced_file.id,
            operation: "conflict_detect",
            details: %{"message" => "Conflict with #{change.name}. Remote copy saved to #{conflict_path}"}
          })

          # Enqueue conflict notification
          enqueue_conflict_notification(synced_file.id, user_id)

        {:error, reason} ->
          Logger.error("SyncPollWorker: conflict copy write failed",
            file_id: change.file_id,
            reason: inspect(reason)
          )

          # Still mark as conflict even if copy failed
          StateStore.update_synced_file(synced_file, %{
            sync_status: "conflict",
            sync_error: "Conflict detected but copy failed: #{inspect(reason)}"
          })
      end
    end
  end

  # -- Trash/Remove Handler --

  defp handle_trash(user_id, synced_file, change) do
    case ChangeDetector.trash_action(synced_file) do
      :ignore ->
        :ok

      :archive ->
        archive_path = ChangeDetector.generate_archive_path(synced_file.local_path)

        case FileManager.rename_file(user_id, synced_file.local_path, archive_path) do
          :ok ->
            operation = if change[:removed], do: "delete_local", else: "trash"

            StateStore.update_synced_file(synced_file, %{
              local_path: archive_path,
              sync_status: "synced",
              sync_error: nil
            })

            StateStore.create_history_entry(%{
              synced_file_id: synced_file.id,
              operation: operation,
              details: %{"message" => "Archived to #{archive_path}"}
            })

          {:error, :enoent} ->
            # Local file was already gone — just update status
            StateStore.update_synced_file(synced_file, %{
              sync_status: "synced",
              sync_error: nil
            })

            StateStore.create_history_entry(%{
              synced_file_id: synced_file.id,
              operation: "delete_local",
              details: %{"message" => "Remote removed; local file was already missing"}
            })

          {:error, reason} ->
            Logger.error("SyncPollWorker: archive failed",
              file_id: change.file_id,
              reason: inspect(reason)
            )
        end
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

  defp build_relative_path(change, format) do
    # Sanitize the file name — replace unsafe characters
    safe_name =
      (change.name || "untitled")
      |> String.replace(~r/[\/\\:*?"<>|]/, "_")
      |> String.slice(0, 200)

    base = Path.rootname(safe_name)
    "#{base}.#{format}"
  end

  defp parse_time(nil), do: nil
  defp parse_time(%DateTime{} = dt), do: dt

  defp parse_time(time_string) when is_binary(time_string) do
    case DateTime.from_iso8601(time_string) do
      {:ok, dt, _offset} -> dt
      {:error, _} -> nil
    end
  end

  defp parse_time(_), do: nil

  defp record_error(user_id, change, message) do
    synced_file = StateStore.get_synced_file(user_id, change.file_id)

    if synced_file do
      StateStore.update_synced_file(synced_file, %{
        sync_status: "error",
        sync_error: message
      })

      StateStore.create_history_entry(%{
        synced_file_id: synced_file.id,
        operation: "error",
        details: %{"message" => message}
      })
    end
  end

  defp enqueue_conflict_notification(synced_file_id, user_id) do
    %{synced_file_id: synced_file_id, user_id: user_id}
    |> Assistant.Sync.Workers.ConflictNotifyWorker.new()
    |> Oban.insert()
  end
end
