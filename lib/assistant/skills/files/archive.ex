# lib/assistant/skills/files/archive.ex — Handler for files.archive skill.
#
# Moves a file into an Archive folder in Google Drive. If no specific
# archive folder is provided, searches for (or creates) a root-level
# folder named "Archive". The search for the Archive folder uses Drive
# scoping to respect enabled drives.
#
# Related files:
#   - lib/assistant/integrations/google/drive.ex (Drive API client — move_file)
#   - lib/assistant/integrations/google/drive/scoping.ex (query param builder)
#   - lib/assistant/skills/handler.ex (behaviour)
#   - priv/skills/files/archive.md (skill definition)

defmodule Assistant.Skills.Files.Archive do
  @moduledoc """
  Skill handler for archiving files in Google Drive.

  Moves a file to a designated Archive folder. When no folder ID is
  specified, looks for a root-level folder named "Archive" and creates
  one if it does not exist.
  """

  @behaviour Assistant.Skills.Handler

  alias Assistant.Skills.Result
  alias Assistant.Integrations.Google.Drive.Scoping
  alias Assistant.Sync.WriteCoordinator

  @archive_folder_name "Archive"
  @folder_mime_type "application/vnd.google-apps.folder"

  @impl true
  def execute(flags, context) do
    case Map.get(context.integrations, :drive) do
      nil ->
        {:ok, %Result{status: :error, content: "Drive integration not configured."}}

      drive ->
        case context.metadata[:google_token] do
          nil ->
            {:ok,
             %Result{
               status: :error,
               content: "Google authentication required. Please connect your Google account."
             }}

          token ->
            do_execute(flags, drive, token, context)
        end
    end
  end

  defp do_execute(flags, drive, token, context) do
    file_id = Map.get(flags, "id")
    folder_id = Map.get(flags, "folder")

    cond do
      is_nil(file_id) || file_id == "" ->
        {:ok, %Result{status: :error, content: "Missing required parameter: --id (file ID)."}}

      true ->
        enabled_drives = context.metadata[:enabled_drives] || []
        archive_file(drive, token, file_id, folder_id, enabled_drives, context)
    end
  end

  defp archive_file(drive, token, file_id, folder_id, enabled_drives, context) do
    with {:ok, archive_id} <- resolve_archive_folder(drive, token, folder_id, enabled_drives),
         {:ok, file_meta} <- drive.get_file(token, file_id),
         {:ok, _moved} <-
           move_with_preconditions(drive, token, file_id, archive_id, file_meta, context) do
      {:ok,
       %Result{
         status: :ok,
         content: "Archived '#{file_meta.name}' to Archive folder.",
         side_effects: [:file_moved],
         metadata: %{file_id: file_id, archive_folder_id: archive_id}
       }}
    else
      {:error, :not_found} ->
        {:ok, %Result{status: :error, content: "File '#{file_id}' not found."}}

      {:error, :conflict} ->
        {:ok,
         %Result{
           status: :error,
           content:
             "This file changed while I was archiving it. I paused to avoid overriding newer changes. Please retry."
         }}

      {:error, reason} ->
        {:ok, %Result{status: :error, content: "Failed to archive file: #{inspect(reason)}"}}
    end
  end

  defp move_with_preconditions(drive, token, file_id, archive_id, file_meta, context) do
    if conflict_protection_enabled?() and function_exported?(drive, :move_file, 5) do
      user_id = context.metadata[:user_id] || "unknown"

      WriteCoordinator.execute(
        fn -> drive.move_file(token, file_id, archive_id, true, precondition_opts(file_meta)) end,
        user_id: user_id,
        file_id: file_id,
        intent_id: "files.archive:#{file_id}",
        classify_error: &classify_drive_error(drive, &1),
        event_hook: maybe_event_hook(context, file_id, "files.archive")
      )
    else
      drive.move_file(token, file_id, archive_id)
    end
  end

  defp precondition_opts(file_meta) do
    []
    |> maybe_put_expected(:expected_modified_time, Map.get(file_meta, :modified_time))
    |> maybe_put_expected(:expected_checksum, Map.get(file_meta, :md5_checksum))
    |> maybe_put_expected(:expected_version, Map.get(file_meta, :version))
  end

  defp maybe_put_expected(opts, _key, nil), do: opts
  defp maybe_put_expected(opts, _key, ""), do: opts
  defp maybe_put_expected(opts, key, value), do: Keyword.put(opts, key, value)

  defp conflict_protection_enabled? do
    Application.get_env(:assistant, :google_write_conflict_protection, false)
  end

  defp audit_history_enabled? do
    Application.get_env(:assistant, :google_write_audit_history, false)
  end

  defp maybe_event_hook(context, file_id, action) do
    user_id = context.metadata[:user_id]

    if audit_history_enabled?() and is_binary(user_id) do
      fn event ->
        Assistant.Sync.StateStore.record_write_coordinator_event(user_id, file_id, action, event)
      end
    else
      nil
    end
  end

  defp classify_drive_error(drive, reason) do
    if function_exported?(drive, :classify_write_error, 1) do
      drive.classify_write_error(reason)
    else
      if reason == :conflict, do: :conflict, else: :fatal
    end
  end

  defp resolve_archive_folder(_drive, _token, folder_id, _enabled_drives)
       when is_binary(folder_id) and folder_id != "" do
    {:ok, folder_id}
  end

  defp resolve_archive_folder(drive, token, _folder_id, enabled_drives) do
    query =
      "name = '#{@archive_folder_name}' and mimeType = '#{@folder_mime_type}' and trashed = false"

    scopes =
      case enabled_drives do
        [] ->
          [[]]

        drives ->
          case Scoping.build_query_params(drives) do
            {:ok, param_sets} -> param_sets
            {:error, :no_drives_enabled} -> [[]]
          end
      end

    find_archive_in_scopes(drive, token, query, scopes)
  end

  # Search each scope until the Archive folder is found, or create one.
  defp find_archive_in_scopes(drive, token, _query, []) do
    create_archive_folder(drive, token)
  end

  defp find_archive_in_scopes(drive, token, query, [scope_opts | rest]) do
    opts = Keyword.merge([pageSize: 1], scope_opts)

    case drive.list_files(token, query, opts) do
      {:ok, [%{id: id} | _]} ->
        {:ok, id}

      {:ok, []} ->
        find_archive_in_scopes(drive, token, query, rest)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp create_archive_folder(drive, token) do
    case drive.create_file(token, @archive_folder_name, "", mime_type: @folder_mime_type) do
      {:ok, %{id: id}} -> {:ok, id}
      {:error, reason} -> {:error, reason}
    end
  end
end
