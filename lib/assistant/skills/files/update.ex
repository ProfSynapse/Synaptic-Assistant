# lib/assistant/skills/files/update.ex — Handler for files.update skill.
#
# Reads a file from the synced workspace, applies a string replacement
# (search -> replace), and writes the modified content back. Marks the
# file as local_ahead and enqueues an upstream sync job.
#
# Related files:
#   - lib/assistant/sync/file_manager.ex (local read/write)
#   - lib/assistant/sync/state_store.ex (path/ID lookup, sync status)
#   - lib/assistant/sync/workers/upstream_sync_worker.ex (upstream push)
#   - priv/skills/files/update.md (skill definition)

defmodule Assistant.Skills.Files.Update do
  @moduledoc """
  Skill handler for updating file content in the synced workspace via
  string replacement.

  Reads the local file, applies `String.replace/4` with the given search
  and replace strings, writes the result back to the workspace, and
  enqueues an upstream sync job.
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
      {:ok, %Result{status: :error, content: "User context is required to update files."}}
    else
      do_execute(flags, user_id, file_manager, state_store)
    end
  end

  defp do_execute(flags, user_id, file_manager, state_store) do
    path = Map.get(flags, "path")
    file_id = Map.get(flags, "id")
    search = Map.get(flags, "search")
    replace = Map.get(flags, "replace")
    replace_all? = Map.get(flags, "all", false)

    cond do
      is_nil(search) || search == "" ->
        {:ok,
         %Result{status: :error, content: "Missing required parameter: --search (text to find)."}}

      is_nil(replace) ->
        {:ok,
         %Result{
           status: :error,
           content: "Missing required parameter: --replace (replacement text)."
         }}

      true ->
        case resolve_file(path, file_id, user_id, state_store) do
          {:ok, synced_file} ->
            do_update(
              file_manager,
              state_store,
              user_id,
              synced_file,
              search,
              replace,
              replace_all?
            )

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

  defp do_update(file_manager, state_store, user_id, synced_file, search, replace, replace_all?) do
    case file_manager.read_file(user_id, synced_file.local_path) do
      {:ok, content} ->
        case apply_replacement(content, search, replace, replace_all?) do
          :unchanged ->
            {:ok, %Result{status: :ok, content: "No changes made (pattern not found)."}}

          {:changed, updated, count} ->
            write_and_sync(
              file_manager,
              state_store,
              user_id,
              synced_file,
              updated,
              search,
              count
            )
        end

      {:error, :enoent} ->
        {:ok,
         %Result{
           status: :error,
           content: "File not found at path '#{synced_file.local_path}'."
         }}

      {:error, reason} ->
        {:ok,
         %Result{
           status: :error,
           content: "Failed to read '#{synced_file.local_path}': #{inspect(reason)}"
         }}
    end
  end

  defp write_and_sync(file_manager, state_store, user_id, synced_file, updated, search, count) do
    case file_manager.write_file(user_id, synced_file.local_path, updated) do
      {:ok, _path} ->
        mark_local_ahead(state_store, synced_file, updated)
        enqueue_upstream_sync(synced_file, user_id)

        name = synced_file.drive_file_name || Path.basename(synced_file.local_path)

        {:ok,
         %Result{
           status: :ok,
           content: "Updated #{name}: replaced #{count} occurrence(s) of '#{search}'.",
           side_effects: [:file_updated],
           metadata: %{
             path: synced_file.local_path,
             file_name: name,
             replacements: count
           }
         }}

      {:error, reason} ->
        {:ok,
         %Result{
           status: :error,
           content: "Failed to write '#{synced_file.local_path}': #{inspect(reason)}"
         }}
    end
  end

  defp apply_replacement(content, search, replace, replace_all?) do
    global = replace_all? == true || replace_all? == "true"
    opts = if global, do: [global: true], else: [global: false]
    updated = String.replace(content, search, replace, opts)

    if updated == content do
      :unchanged
    else
      total = length(String.split(content, search)) - 1
      count = if global, do: total, else: min(total, 1)
      {:changed, updated, count}
    end
  end

  defp mark_local_ahead(state_store, synced_file, content) do
    checksum = FileManager.checksum(content)
    now = DateTime.utc_now()

    attrs =
      if local_conflict_copy?(synced_file) do
        %{
          sync_status: "conflict",
          local_checksum: checksum,
          local_modified_at: now
        }
      else
        %{
          sync_status: "local_ahead",
          local_checksum: checksum,
          local_modified_at: now
        }
      end

    state_store.update_synced_file(synced_file, attrs)
  end

  defp enqueue_upstream_sync(synced_file, user_id) do
    if local_conflict_copy?(synced_file) do
      :ok
    else
      intent_id = "files.update:#{synced_file.drive_file_id}:#{System.system_time(:millisecond)}"

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

  defp local_conflict_copy?(synced_file) do
    String.starts_with?(synced_file.drive_file_id || "", "local-conflict:")
  end
end
