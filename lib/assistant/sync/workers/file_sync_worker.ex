defmodule Assistant.Sync.Workers.FileSyncWorker do
  @moduledoc """
  Processes an individual file synced down from Google Drive.
  """
  use Oban.Worker,
    queue: :google_drive_sync,
    max_attempts: 7

  require Logger

  alias Assistant.Sync.{Converter, FileManager, StateStore}
  alias Assistant.Schemas.SyncedFile

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    # Normalize string keys back to atoms safely
    action = args["action"]
    user_id = args["user_id"]
    file_id = args["drive_file_id"]
    change = string_keys_to_atoms(args["change"])
    access_token = args["access_token"]
    drive_id = args["drive_id"]

    case action do
      "upsert" -> handle_update(user_id, file_id, drive_id, access_token, change)
      "delete" -> handle_trash(user_id, file_id, change)
    end
  end

  defp handle_update(user_id, file_id, drive_id, access_token, change) do
    Logger.debug("FileSyncWorker: Upserting file #{change.name} (#{file_id})")

    # Detect conflict before downloading
    local_state = StateStore.get_synced_file(user_id, file_id)

    if Assistant.Sync.ChangeDetector.detect_conflict(local_state, change) == :conflict do
      Logger.warning("FileSyncWorker: Conflict detected for #{change.name}")

      if local_state do
        StateStore.update_synced_file(local_state, %{sync_status: "conflict"})
      end

      # Could enqueue a conflict notify job here
      :ok
    else
      do_download_and_convert(user_id, file_id, drive_id, access_token, change, local_state)
    end
  end

  defp handle_trash(user_id, file_id, _change) do
    Logger.info("FileSyncWorker: Trashing file #{file_id}")

    case StateStore.get_synced_file(user_id, file_id) do
      nil ->
        :ok

      %SyncedFile{sync_status: "local_ahead"} = state ->
        # Do not delete if the user modified it locally in the meantime. 
        # Mark as conflict instead.
        Logger.warning("FileSyncWorker: Conflict on trash for #{file_id}")
        StateStore.update_synced_file(state, %{sync_status: "conflict"})
        :ok

      %SyncedFile{local_path: local_path} = state ->
        # Normal delete
        FileManager.delete_file(user_id, local_path)
        StateStore.delete_synced_file(state)
        :ok
    end
  end

  defp do_download_and_convert(user_id, file_id, drive_id, access_token, change, local_state) do
    mime = change.mime_type || "application/octet-stream"

    size =
      case Map.get(change, :size) do
        nil -> 0
        "" -> 0
        s when is_binary(s) -> String.to_integer(s)
        i when is_integer(i) -> i
      end

    cond do
      size > 50_000_000 ->
        log_too_large(change)

      true ->
        case Converter.convert(access_token, file_id, mime) do
          {:ok, {converted_content, final_format}} ->
            # Ecto changeset needs new sync info
            relative_path = resolve_format_and_path(change, final_format, local_state)

            case FileManager.write_file(user_id, relative_path, converted_content) do
              {:ok, _db_record} ->
                attrs = %{
                  user_id: user_id,
                  drive_file_id: file_id,
                  drive_file_name: change.name,
                  drive_mime_type: mime,
                  local_path: relative_path,
                  local_format: final_format,
                  remote_modified_at: change.modified_time,
                  remote_checksum: FileManager.checksum(converted_content),
                  local_modified_at: DateTime.utc_now(),
                  local_checksum: FileManager.checksum(converted_content),
                  sync_status: "synced",
                  last_synced_at: DateTime.utc_now(),
                  drive_id: drive_id,
                  file_size:
                    Map.get(change, :size)
                    |> case do
                      nil -> byte_size(converted_content)
                      s when is_binary(s) -> String.to_integer(s)
                      i when is_integer(i) -> i
                    end
                }

                if local_state do
                  StateStore.update_synced_file(local_state, attrs)
                else
                  StateStore.create_synced_file(attrs)
                end

                :ok

              {:error, reason} ->
                Logger.error("FileSyncWorker: FileManager write failed - #{inspect(reason)}")
                record_error(user_id, file_id, change, "Failed to write to DB Sandbox")
            end

          {:error, reason} ->
            Logger.error("FileSyncWorker: Drive fetch failed - #{inspect(reason)}")
            record_error(user_id, file_id, change, inspect(reason))
        end
    end
  end

  defp resolve_format_and_path(change, final_format, local_state) do
    if local_state do
      local_state.local_path
    else
      base_name =
        (change.name || "Untitled")
        |> String.replace(~r/[^\w\s\.-]/, "_")

      "#{base_name}.#{final_format}"
    end
  end

  defp log_too_large(change) do
    Logger.debug("FileSyncWorker: Skipping large file: #{change.name} (#{change.size} bytes)")
    :ok
  end

  defp record_error(user_id, file_id, change, error_msg) do
    attrs = %{
      user_id: user_id,
      drive_file_id: file_id,
      drive_file_name: change.name || "Unknown",
      drive_mime_type: change.mime_type || "application/octet-stream",
      local_path: "error_#{file_id}.txt",
      local_format: "txt",
      sync_status: "error",
      sync_error: String.slice(error_msg, 0, 255)
    }

    local_state = StateStore.get_synced_file(user_id, file_id)

    if local_state do
      StateStore.update_synced_file(local_state, attrs)
    else
      StateStore.create_synced_file(attrs)
    end

    # Return error so Oban retries it
    {:error, error_msg}
  end

  defp string_keys_to_atoms(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {String.to_atom(k), v} end)
  end

  defp string_keys_to_atoms(other), do: other
end
