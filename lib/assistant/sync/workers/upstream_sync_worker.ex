defmodule Assistant.Sync.Workers.UpstreamSyncWorker do
  @moduledoc """
  Handles pushing local modifications (from the agent's sandbox changes)
  back to the Google Drive API.

  When a SyncedFile is marked as `local_ahead`, this worker pushes the local
  content back to Google Drive. It also handles archive/trash requests for
  files that were removed locally.
  """
  use Oban.Worker,
    queue: :google_drive_sync,
    max_attempts: 7

  require Logger

  alias Assistant.Repo
  alias Assistant.Integrations.Google.Auth
  alias Assistant.Schemas.SyncedFile
  alias Assistant.Sync.{Helpers, StateStore}

  @impl Oban.Worker
  def perform(%Oban.Job{
        args: %{"action" => "trash", "drive_file_id" => file_id, "user_id" => user_id}
      }) do
    Logger.info("UpstreamSyncWorker: Trashing file #{file_id} for user #{user_id}")

    synced_file = Repo.get_by(SyncedFile, user_id: user_id, drive_file_id: file_id)
    trash_remote_file(user_id, file_id, synced_file)
  end

  def perform(%Oban.Job{
        args:
          %{
            "action" => "write_intent",
            "user_id" => user_id,
            "drive_file_id" => file_id,
            "intent_id" => intent_id
          } = args
      }) do
    Logger.info("UpstreamSyncWorker: Processing write intent",
      user_id: user_id,
      drive_file_id: file_id,
      intent_id: intent_id
    )

    if StateStore.write_intent_already_applied?(user_id, file_id, intent_id) do
      Logger.info("UpstreamSyncWorker: Skipping replayed write intent",
        user_id: user_id,
        drive_file_id: file_id,
        intent_id: intent_id
      )

      :ok
    else
      _ =
        StateStore.record_upstream_intent_event(user_id, file_id, intent_id, "attempt", %{
          "args" => Map.drop(args, ["action"])
        })

      case Repo.get_by(SyncedFile, user_id: user_id, drive_file_id: file_id) do
        nil ->
          _ =
            StateStore.record_upstream_intent_event(user_id, file_id, intent_id, "failure", %{
              "reason" => "synced_file_not_found"
            })

          {:discard, :synced_file_not_found}

        synced_file ->
          push_intent_to_drive(synced_file, user_id, file_id, intent_id)
      end
    end
  end

  def perform(%Oban.Job{args: %{"synced_file_id" => id}}) do
    Logger.info("UpstreamSyncWorker: Processing synced_file_id #{id}")

    case Repo.get(SyncedFile, id) do
      nil ->
        Logger.warning("UpstreamSyncWorker: SyncedFile #{id} not found, dropping job.")
        :ok

      %SyncedFile{sync_status: "local_ahead"} = synced_file ->
        push_updates_to_drive(synced_file)

      synced_file ->
        Logger.info(
          "UpstreamSyncWorker: SyncedFile #{id} is not local_ahead (status: #{synced_file.sync_status}). Skipping."
        )

        :ok
    end
  end

  defp push_updates_to_drive(synced_file) do
    push_intent_to_drive(synced_file, synced_file.user_id, synced_file.drive_file_id, nil)
  end

  defp push_intent_to_drive(synced_file, user_id, file_id, intent_id) do
    with {:ok, access_token} <- Auth.user_token(user_id),
         {:ok, local_content} <- synced_file_content(synced_file),
         {:ok, remote_file} <-
           drive_module().update_file_content(
             access_token,
             file_id,
             local_content,
             upload_mime_type(synced_file),
             write_preconditions(synced_file)
           ),
         {:ok, _updated} <- mark_synced_after_write(synced_file, remote_file),
         :ok <- record_write_intent_success(user_id, file_id, intent_id, remote_file) do
      :ok
    else
      {:error, :not_connected} = error ->
        record_write_intent_failure(user_id, file_id, intent_id, "google_account_not_connected")
        mark_sync_error(synced_file, "Google account is not connected")
        discard_or_error(error)

      {:error, :refresh_failed} = error ->
        record_write_intent_failure(user_id, file_id, intent_id, "google_refresh_failed")
        mark_sync_error(synced_file, "Google access token refresh failed")
        discard_or_error(error)

      {:error, :missing_content} = error ->
        record_write_intent_failure(user_id, file_id, intent_id, "missing_local_content")
        mark_sync_error(synced_file, "Synced file has no local content to push")
        discard_or_error(error)

      {:error, :not_found} = error ->
        record_write_intent_failure(user_id, file_id, intent_id, "remote_file_not_found")
        mark_sync_error(synced_file, "Remote file no longer exists")
        discard_or_error(error)

      {:error, :conflict} = error ->
        record_write_intent_failure(user_id, file_id, intent_id, "remote_conflict")
        mark_sync_conflict(synced_file, "Remote file changed before upstream sync")
        discard_or_error(error)

      {:error, reason} ->
        case drive_module().classify_write_error(reason) do
          :transient ->
            record_write_intent_failure(user_id, file_id, intent_id, inspect(reason))
            {:error, reason}

          :conflict ->
            record_write_intent_failure(user_id, file_id, intent_id, "remote_conflict")
            mark_sync_conflict(synced_file, "Remote file changed before upstream sync")
            discard_or_error({:error, :conflict})

          :fatal ->
            record_write_intent_failure(user_id, file_id, intent_id, inspect(reason))
            mark_sync_error(synced_file, inspect(reason))
            discard_or_error({:error, reason})
        end
    end
  end

  defp trash_remote_file(user_id, file_id, synced_file) do
    with {:ok, access_token} <- Auth.user_token(user_id),
         {:ok, remote_file} <-
           drive_module().trash_file(access_token, file_id, trash_preconditions(synced_file)),
         :ok <- mark_synced_after_trash(synced_file, remote_file) do
      :ok
    else
      {:error, :not_connected} = error ->
        mark_sync_error(synced_file, "Google account is not connected")
        discard_or_error(error)

      {:error, :refresh_failed} = error ->
        mark_sync_error(synced_file, "Google access token refresh failed")
        discard_or_error(error)

      {:error, :not_found} ->
        Logger.info(
          "UpstreamSyncWorker: remote file #{file_id} already missing; treating trash as complete"
        )

        mark_synced_after_trash(synced_file, %{modified_time: nil})

      {:error, :conflict} = error ->
        mark_sync_conflict(synced_file, "Remote file changed before trash")
        discard_or_error(error)

      {:error, reason} ->
        case drive_module().classify_write_error(reason) do
          :transient ->
            {:error, reason}

          :conflict ->
            mark_sync_conflict(synced_file, "Remote file changed before trash")
            discard_or_error({:error, :conflict})

          :fatal ->
            mark_sync_error(synced_file, inspect(reason))
            discard_or_error({:error, reason})
        end
    end
  end

  defp mark_synced_after_write(synced_file, remote_file) do
    now = DateTime.utc_now()
    remote_modified_at = remote_time(remote_file, :modified_time)

    synced_file
    |> StateStore.update_synced_file(sync_attrs_from_remote(remote_file, now, remote_modified_at))
  end

  defp mark_synced_after_trash(nil, _remote_file), do: :ok

  defp mark_synced_after_trash(synced_file, remote_file) do
    now = DateTime.utc_now()
    remote_modified_at = remote_time(remote_file, :modified_time)

    case StateStore.update_synced_file(
           synced_file,
           sync_attrs_from_remote(remote_file, now, remote_modified_at)
         ) do
      {:ok, _updated} -> :ok
      {:error, _changeset} = error -> error
    end
  end

  defp mark_sync_conflict(nil, _message), do: :ok

  defp mark_sync_conflict(synced_file, message) do
    synced_file
    |> StateStore.update_synced_file(%{sync_status: "conflict", sync_error: message})
  end

  defp mark_sync_error(nil, _message), do: :ok

  defp mark_sync_error(synced_file, message) do
    synced_file
    |> StateStore.update_synced_file(%{sync_status: "error", sync_error: message})
  end

  defp record_write_intent_success(_user_id, _file_id, nil, _remote_file), do: :ok

  defp record_write_intent_success(user_id, file_id, intent_id, remote_file) do
    StateStore.record_upstream_intent_event(user_id, file_id, intent_id, "success", %{
      "remote_modified_time" => remote_value(remote_file, :modified_time),
      "remote_checksum" => remote_value(remote_file, :md5_checksum)
    })
  end

  defp record_write_intent_failure(_user_id, _file_id, nil, _reason), do: :ok

  defp record_write_intent_failure(user_id, file_id, intent_id, reason) do
    StateStore.record_upstream_intent_event(user_id, file_id, intent_id, "failure", %{
      "reason" => reason
    })
  end

  defp discard_or_error({:error, reason})
       when reason in [
              :not_connected,
              :refresh_failed,
              :conflict,
              :not_found,
              :synced_file_not_found
            ],
       do: {:discard, reason}

  defp discard_or_error({:error, reason}), do: {:discard, reason}

  defp synced_file_content(%SyncedFile{content: content}) when is_binary(content),
    do: {:ok, content}

  defp synced_file_content(%SyncedFile{content: nil}), do: {:error, :missing_content}

  defp upload_mime_type(%SyncedFile{drive_mime_type: mime_type})
       when is_binary(mime_type) and mime_type != "",
       do: mime_type

  defp upload_mime_type(_), do: "text/plain"

  defp write_preconditions(%SyncedFile{remote_modified_at: %DateTime{} = dt}),
    do: [expected_modified_time: dt]

  defp write_preconditions(%SyncedFile{remote_modified_at: nil}), do: []

  defp trash_preconditions(nil), do: []

  defp trash_preconditions(%SyncedFile{remote_modified_at: %DateTime{} = dt}),
    do: [expected_modified_time: dt]

  defp trash_preconditions(%SyncedFile{remote_modified_at: nil}), do: []

  defp sync_attrs_from_remote(remote_file, now, remote_modified_at) do
    %{
      sync_status: "synced",
      last_synced_at: now,
      sync_error: nil
    }
    |> maybe_put(:remote_modified_at, remote_modified_at)
    |> maybe_put(:remote_checksum, remote_value(remote_file, :md5_checksum))
    |> maybe_put(:drive_file_name, remote_value(remote_file, :name))
    |> maybe_put(:file_size, remote_integer_value(remote_file, :size))
  end

  defp remote_time(remote_file, key) do
    remote_file
    |> remote_value(key)
    |> Helpers.parse_time()
  end

  defp remote_integer_value(remote_file, key) do
    case remote_value(remote_file, key) do
      nil ->
        nil

      value when is_integer(value) ->
        value

      value when is_binary(value) ->
        case Integer.parse(value) do
          {parsed, _} -> parsed
          :error -> nil
        end

      _ ->
        nil
    end
  end

  defp remote_value(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, to_string(key))
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp drive_module do
    Application.get_env(:assistant, :google_drive_module, Assistant.Integrations.Google.Drive)
  end
end
