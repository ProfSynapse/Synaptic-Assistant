defmodule Assistant.Sync.Workers.FileSyncWorker do
  @moduledoc """
  Processes an individual file synced down from Google Drive.
  """
  use Oban.Worker,
    queue: :sync,
    max_attempts: 7

  require Logger

  alias Assistant.Billing.Policy
  alias Assistant.Repo
  alias Assistant.Schemas.SyncedFile
  alias Assistant.Sync.{ChangeDetector, Converter, Helpers, StateStore}

  @auth_fun_env :sync_google_auth_fun
  @converter_fun_env :sync_google_converter_fun

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    action = Map.get(args, "action")
    user_id = Map.get(args, "user_id")
    file_id = Map.get(args, "drive_file_id")
    drive_id = Map.get(args, "drive_id")
    change = normalize_change(Map.get(args, "change"))

    case action do
      "upsert" ->
        case resolve_access_token(user_id) do
          {:ok, access_token} ->
            handle_update(user_id, file_id, drive_id, access_token, change)

          {:error, reason} ->
            Logger.warning(
              "FileSyncWorker: skipping file #{file_id}, auth error: #{inspect(reason)}"
            )

            :ok
        end

      "delete" ->
        handle_trash(user_id, file_id, change)

      other ->
        {:error, {:unsupported_action, other}}
    end
  end

  defp handle_update(user_id, file_id, drive_id, access_token, change) do
    Logger.debug("FileSyncWorker: Upserting file #{change.name} (#{file_id})")

    # Detect conflict before downloading
    local_state = StateStore.get_synced_file(user_id, file_id)

    if ChangeDetector.detect_conflict(local_state, change) == :conflict do
      Logger.warning("FileSyncWorker: Conflict detected for #{change.name}")

      if local_state do
        create_conflict_copy(local_state)
        StateStore.update_synced_file(local_state, %{sync_status: "conflict"})
        enqueue_conflict_notification(local_state.id, user_id)
      end

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
        create_conflict_copy(state)
        StateStore.update_synced_file(state, %{sync_status: "conflict"})
        enqueue_conflict_notification(state.id, user_id)
        :ok

      %SyncedFile{} = state ->
        # Normal delete
        delete_synced_file(state)
        :ok
    end
  end

  defp do_download_and_convert(user_id, file_id, drive_id, access_token, change, local_state) do
    mime = change.mime_type || "application/octet-stream"
    size = parse_size(change.size, 0)

    cond do
      size > 50_000_000 ->
        log_too_large(change)

      true ->
        case converter_fun().(access_token, file_id, mime) do
          {:ok, {converted_content, final_format}} ->
            upsert_local_copy(
              user_id,
              file_id,
              drive_id,
              change,
              local_state,
              converted_content,
              final_format
            )

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

  defp upsert_local_copy(user_id, file_id, drive_id, change, nil, converted_content, final_format) do
    now = DateTime.utc_now()
    checksum = checksum(converted_content)

    attrs =
      import_attrs(
        user_id,
        file_id,
        drive_id,
        change,
        final_format,
        converted_content,
        checksum,
        now,
        nil
      )

    case StateStore.create_synced_file(attrs) do
      {:ok, _synced_file} ->
        :ok

      {:error, reason} ->
        Logger.error("FileSyncWorker: Failed to create synced file - #{inspect(reason)}")
        record_error(user_id, file_id, change, inspect(reason))
    end
  end

  defp upsert_local_copy(
         user_id,
         file_id,
         drive_id,
         change,
         %SyncedFile{} = local_state,
         converted_content,
         final_format
       ) do
    now = DateTime.utc_now()
    checksum = checksum(converted_content)

    attrs =
      import_attrs(
        user_id,
        file_id,
        drive_id,
        change,
        final_format,
        converted_content,
        checksum,
        now,
        local_state
      )

    with :ok <-
           Policy.ensure_retained_write_allowed(
             user_id,
             Policy.synced_file_growth(local_state.content, converted_content)
           ),
         {:ok, _synced_file} <-
           local_state
           |> Ecto.Changeset.change(Map.put(attrs, :content, converted_content))
           |> Repo.update() do
      :ok
    else
      {:error, reason} ->
        Logger.error("FileSyncWorker: Failed to update synced file - #{inspect(reason)}")
        record_error(user_id, file_id, change, inspect(reason))
    end
  end

  defp import_attrs(
         user_id,
         file_id,
         drive_id,
         change,
         final_format,
         converted_content,
         checksum,
         now,
         local_state
       ) do
    %{
      user_id: user_id,
      drive_file_id: file_id,
      drive_file_name: change.name || "Untitled",
      drive_mime_type: change.mime_type || "application/octet-stream",
      local_path: resolve_format_and_path(change, final_format, local_state),
      local_format: final_format,
      remote_modified_at: Helpers.parse_time(change.modified_time),
      remote_checksum: checksum,
      local_modified_at: now,
      local_checksum: checksum,
      sync_status: "synced",
      last_synced_at: now,
      drive_id: drive_id,
      file_size: parse_size(change.size, byte_size(converted_content)),
      content: converted_content
    }
  end

  defp checksum(content) do
    :crypto.hash(:sha256, content)
    |> Base.encode16(case: :lower)
    |> String.slice(0, 16)
  end

  defp parse_size(nil, default), do: default
  defp parse_size("", default), do: default
  defp parse_size(value, _default) when is_integer(value), do: value

  defp parse_size(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {int, _rest} -> int
      :error -> default
    end
  end

  defp delete_synced_file(%SyncedFile{} = state) do
    StateStore.delete_synced_file(state)
  end

  defp create_conflict_copy(%SyncedFile{content: nil}), do: :ok

  defp create_conflict_copy(%SyncedFile{} = state) do
    local_path = conflict_copy_path(state)
    timestamp = System.system_time(:microsecond)
    now = DateTime.utc_now()
    local_checksum = state.local_checksum || checksum(state.content)

    attrs = %{
      user_id: state.user_id,
      drive_file_id: "local-conflict:#{state.drive_file_id}:#{timestamp}",
      drive_file_name: "#{state.drive_file_name || "Untitled"} (conflict copy)",
      drive_mime_type: state.drive_mime_type || "application/octet-stream",
      local_path: local_path,
      local_format: state.local_format || format_from_path(local_path),
      remote_modified_at: state.remote_modified_at,
      local_modified_at: now,
      remote_checksum: state.remote_checksum,
      local_checksum: local_checksum,
      sync_status: "conflict",
      last_synced_at: state.last_synced_at,
      sync_error: "Conflict copy preserved from local changes",
      drive_id: state.drive_id,
      file_size: state.file_size || byte_size(state.content),
      content: state.content
    }

    case StateStore.create_synced_file(attrs) do
      {:ok, _copy} ->
        :ok

      {:error, reason} ->
        Logger.warning("FileSyncWorker: Failed to preserve conflict copy - #{inspect(reason)}")
        :ok
    end
  end

  defp conflict_copy_path(%SyncedFile{} = state) do
    original_path = state.local_path || fallback_local_path(state)
    base_path = ChangeDetector.generate_conflict_path(original_path)

    ensure_unique_local_path(state.user_id, base_path, 0)
  end

  defp ensure_unique_local_path(user_id, base_path, attempt) do
    candidate =
      if attempt == 0 do
        base_path
      else
        ext = Path.extname(base_path)
        root = Path.rootname(base_path, ext)
        "#{root}-#{attempt}#{ext}"
      end

    case StateStore.get_synced_file_by_local_path(user_id, candidate) do
      nil -> candidate
      _existing -> ensure_unique_local_path(user_id, base_path, attempt + 1)
    end
  end

  defp fallback_local_path(%SyncedFile{} = state) do
    sanitized_name =
      (state.drive_file_name || "conflict_copy")
      |> String.replace(~r/[^\w\s\.-]/, "_")

    "#{sanitized_name}.#{state.local_format || "txt"}"
  end

  defp format_from_path(path) do
    path
    |> Path.extname()
    |> String.trim_leading(".")
    |> case do
      "" -> "txt"
      ext -> ext
    end
  end

  defp enqueue_conflict_notification(synced_file_id, user_id) do
    %{synced_file_id: synced_file_id, user_id: user_id}
    |> Assistant.Sync.Workers.ConflictNotifyWorker.new()
    |> Oban.insert()

    :ok
  rescue
    _ -> :ok
  end

  defp resolve_access_token(user_id) do
    auth_fun().(user_id)
  end

  defp auth_fun do
    Application.get_env(
      :assistant,
      @auth_fun_env,
      &Assistant.Integrations.Google.Auth.user_token/1
    )
  end

  defp converter_fun do
    Application.get_env(:assistant, @converter_fun_env, &Converter.convert/4)
  end

  defp normalize_change(nil), do: %{}

  defp normalize_change(change) when is_map(change) do
    %{
      file_id: change_value(change, :file_id),
      removed: truthy?(change_value(change, :removed)),
      name: change_value(change, :name),
      mime_type: change_value(change, :mime_type),
      modified_time: change_value(change, :modified_time),
      size: change_value(change, :size),
      parents: change_value(change, :parents),
      trashed: truthy?(change_value(change, :trashed))
    }
  end

  defp change_value(map, key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp truthy?(value), do: value == true
end
