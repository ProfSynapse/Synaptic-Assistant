# lib/assistant/skills/files/archive.ex — Handler for files.archive skill.
#
# Archives a file in the synced workspace by clearing its local content
# and enqueuing an upstream trash job to remove it from Google Drive.
#
# Related files:
#   - lib/assistant/sync/file_manager.ex (local delete)
#   - lib/assistant/sync/state_store.ex (path/ID lookup)
#   - lib/assistant/sync/workers/upstream_sync_worker.ex (upstream trash)
#   - priv/skills/files/archive.md (skill definition)

defmodule Assistant.Skills.Files.Archive do
  @moduledoc """
  Skill handler for archiving files in the synced workspace.

  Archives a file by clearing its local content (soft delete) and
  enqueuing an upstream sync job to trash the file in Google Drive.
  """

  @behaviour Assistant.Skills.Handler

  alias Assistant.Skills.Result
  alias Assistant.Sync.{FileManager, StateStore}

  require Logger

  @impl true
  def execute(flags, context) do
    user_id = context.user_id
    file_manager = Map.get(context.integrations, :file_manager) || FileManager
    state_store = Map.get(context.integrations, :state_store) || StateStore

    if is_nil(user_id) do
      {:ok, %Result{status: :error, content: "User context is required to archive files."}}
    else
      do_execute(flags, user_id, file_manager, state_store)
    end
  end

  defp do_execute(flags, user_id, file_manager, state_store) do
    path = Map.get(flags, "path")
    file_id = Map.get(flags, "id")

    case resolve_file(path, file_id, user_id, state_store) do
      {:ok, synced_file} ->
        archive_local(file_manager, user_id, synced_file)

      {:error, message} ->
        {:ok, %Result{status: :error, content: message}}
    end
  end

  defp resolve_file(path, _file_id, user_id, state_store)
       when is_binary(path) and path != "" do
    case state_store.get_synced_file_by_local_path(user_id, path) do
      nil -> {:error, "File not found at path '#{path}'. Use files.search to find available files."}
      synced_file -> {:ok, synced_file}
    end
  end

  defp resolve_file(_path, file_id, user_id, state_store)
       when is_binary(file_id) and file_id != "" do
    case state_store.get_synced_file(user_id, file_id) do
      nil -> {:error, "File not found: no synced file with Drive ID '#{file_id}'."}
      synced_file -> {:ok, synced_file}
    end
  end

  defp resolve_file(_path, _file_id, _user_id, _state_store) do
    {:error, "Missing required parameter: --path (workspace file path) or --id (Drive file ID)."}
  end

  defp archive_local(file_manager, user_id, synced_file) do
    name = synced_file.drive_file_name || Path.basename(synced_file.local_path)

    case file_manager.delete_file(user_id, synced_file.local_path) do
      :ok ->
        enqueue_upstream_trash(synced_file, user_id)

        {:ok,
         %Result{
           status: :ok,
           content: "Archived '#{name}'. It will be trashed in Google Drive shortly.",
           side_effects: [:file_archived],
           metadata: %{path: synced_file.local_path, file_name: name}
         }}

      {:error, :path_not_allowed} ->
        {:ok, %Result{status: :error, content: "Invalid path: directory traversal is not allowed."}}

      {:error, reason} ->
        {:ok,
         %Result{
           status: :error,
           content: "Failed to archive '#{name}': #{inspect(reason)}"
         }}
    end
  end

  defp enqueue_upstream_trash(synced_file, user_id) do
    %{
      action: "trash",
      user_id: user_id,
      drive_file_id: synced_file.drive_file_id
    }
    |> Assistant.Sync.Workers.UpstreamSyncWorker.new()
    |> Oban.insert()
    |> case do
      {:ok, _job} -> :ok
      {:error, reason} -> Logger.warning("Failed to enqueue upstream trash: #{inspect(reason)}")
    end
  end
end
