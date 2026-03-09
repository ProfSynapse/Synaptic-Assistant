# lib/assistant/skills/files/write.ex — Handler for files.write skill.
#
# Writes content to a file in the user's synced workspace by local path
# (or Drive file ID lookup). Marks the file as local_ahead and enqueues
# an UpstreamSyncWorker job to push changes back to Drive asynchronously.
#
# Related files:
#   - lib/assistant/sync/file_manager.ex (local write)
#   - lib/assistant/sync/state_store.ex (path/ID lookup, sync status)
#   - lib/assistant/sync/workers/upstream_sync_worker.ex (upstream push)
#   - priv/skills/files/write.md (skill definition)

defmodule Assistant.Skills.Files.Write do
  @moduledoc """
  Skill handler for writing file content in the synced workspace.

  Writes content to an existing synced file identified by local path or
  Drive file ID. After writing, marks the file as `local_ahead` and
  enqueues an upstream sync job to propagate changes to Google Drive.
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
      {:ok, %Result{status: :error, content: "User context is required to write files."}}
    else
      do_execute(flags, user_id, file_manager, state_store)
    end
  end

  defp do_execute(flags, user_id, file_manager, state_store) do
    path = Map.get(flags, "path") || Map.get(flags, "name")
    file_id = Map.get(flags, "id")
    content = Map.get(flags, "content", "")

    cond do
      is_nil(content) ->
        {:ok,
         %Result{status: :error, content: "Missing required parameter: --content (file content)."}}

      true ->
        case resolve_file(path, file_id, user_id, state_store) do
          {:ok, synced_file} ->
            write_local(file_manager, state_store, user_id, synced_file, content)

          {:error, message} ->
            {:ok, %Result{status: :error, content: message}}
        end
    end
  end

  defp resolve_file(path, _file_id, user_id, state_store)
       when is_binary(path) and path != "" do
    case state_store.get_synced_file_by_local_path(user_id, path) do
      nil ->
        {:error, "File not found at path '#{path}'. Use files.search to find available files."}

      synced_file ->
        {:ok, synced_file}
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

  defp write_local(file_manager, state_store, user_id, synced_file, content) do
    case file_manager.write_file(user_id, synced_file.local_path, content) do
      {:ok, _path} ->
        mark_local_ahead(state_store, synced_file, content)
        enqueue_upstream_sync(synced_file, user_id)

        name = synced_file.drive_file_name || Path.basename(synced_file.local_path)

        {:ok,
         %Result{
           status: :ok,
           content: "File updated successfully.\nName: #{name}\nPath: #{synced_file.local_path}",
           side_effects: [:file_updated],
           metadata: %{path: synced_file.local_path, file_name: name}
         }}

      {:error, :enoent} ->
        {:ok,
         %Result{
           status: :error,
           content: "File record exists but content write failed (file not found)."
         }}

      {:error, :path_not_allowed} ->
        {:ok,
         %Result{status: :error, content: "Invalid path: directory traversal is not allowed."}}

      {:error, reason} ->
        {:ok,
         %Result{
           status: :error,
           content: "Failed to write '#{synced_file.local_path}': #{inspect(reason)}"
         }}
    end
  end

  defp mark_local_ahead(state_store, synced_file, content) do
    checksum = FileManager.checksum(content)
    now = DateTime.utc_now()

    state_store.update_synced_file(synced_file, %{
      sync_status: "local_ahead",
      local_checksum: checksum,
      local_modified_at: now
    })
  end

  defp enqueue_upstream_sync(synced_file, user_id) do
    intent_id = "files.write:#{synced_file.drive_file_id}:#{System.system_time(:millisecond)}"

    %{
      action: "write_intent",
      user_id: user_id,
      drive_file_id: synced_file.drive_file_id,
      intent_id: intent_id
    }
    |> Assistant.Sync.Workers.UpstreamSyncWorker.new()
    |> Oban.insert()
    |> case do
      {:ok, _job} -> :ok
      {:error, reason} -> Logger.warning("Failed to enqueue upstream sync: #{inspect(reason)}")
    end
  end
end
