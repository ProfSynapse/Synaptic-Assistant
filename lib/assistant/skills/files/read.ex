# lib/assistant/skills/files/read.ex — Handler for files.read skill.
#
# Reads a file from the user's synced workspace by local path (or Drive
# file ID lookup). All content is served from the local encrypted store —
# no Drive API calls are made.
#
# Related files:
#   - lib/assistant/sync/file_manager.ex (local read)
#   - lib/assistant/sync/state_store.ex (path/ID lookup)
#   - priv/skills/files/read.md (skill definition)

defmodule Assistant.Skills.Files.Read do
  @moduledoc """
  Skill handler for reading file content from the synced workspace.

  Looks up the file by local path (preferred) or Drive file ID, then
  reads the decrypted content from the database. Output is truncated at
  8 000 characters to protect LLM context budgets.
  """

  @behaviour Assistant.Skills.Handler

  alias Assistant.Skills.Result
  alias Assistant.Sync.{FileManager, StateStore}

  @max_content_length 8_000

  @impl true
  def execute(flags, context) do
    user_id = context.user_id
    file_manager = Map.get(context.integrations, :file_manager) || FileManager
    state_store = Map.get(context.integrations, :state_store) || StateStore

    if is_nil(user_id) do
      {:ok, %Result{status: :error, content: "User context is required to read files."}}
    else
      do_execute(flags, user_id, file_manager, state_store)
    end
  end

  defp do_execute(flags, user_id, file_manager, state_store) do
    path = Map.get(flags, "path")
    file_id = Map.get(flags, "id")

    case resolve_path(path, file_id, user_id, state_store) do
      {:ok, local_path, file_name} ->
        read_and_format(file_manager, user_id, local_path, file_name)

      {:error, message} ->
        {:ok, %Result{status: :error, content: message}}
    end
  end

  defp resolve_path(path, _file_id, _user_id, _state_store)
       when is_binary(path) and path != "" do
    {:ok, path, Path.basename(path)}
  end

  defp resolve_path(_path, file_id, user_id, state_store)
       when is_binary(file_id) and file_id != "" do
    case state_store.get_synced_file(user_id, file_id) do
      nil ->
        {:error, "File not found: no synced file with Drive ID '#{file_id}'."}

      synced_file ->
        name = synced_file.drive_file_name || Path.basename(synced_file.local_path)
        {:ok, synced_file.local_path, name}
    end
  end

  defp resolve_path(_path, _file_id, _user_id, _state_store) do
    {:error, "Missing required parameter: --path (workspace file path) or --id (Drive file ID)."}
  end

  defp read_and_format(file_manager, user_id, local_path, file_name) do
    case file_manager.read_file(user_id, local_path) do
      {:ok, content} ->
        {display_content, truncated?} = maybe_truncate(content)

        truncation_note =
          if truncated?,
            do:
              "\n\n...content truncated at #{@max_content_length} characters. Full file available in workspace.",
            else: ""

        {:ok,
         %Result{
           status: :ok,
           content: "## #{file_name}\n\n#{display_content}#{truncation_note}",
           metadata: %{
             path: local_path,
             content_length: byte_size(content),
             truncated: truncated?
           }
         }}

      {:error, :enoent} ->
        {:ok,
         %Result{
           status: :error,
           content:
             "File not found at path '#{local_path}'. Use files.search to find available files."
         }}

      {:error, :path_not_allowed} ->
        {:ok, %Result{status: :error, content: "Invalid path: directory traversal is not allowed."}}

      {:error, reason} ->
        {:ok,
         %Result{status: :error, content: "Failed to read '#{local_path}': #{inspect(reason)}"}}
    end
  end

  defp maybe_truncate(content) do
    if String.length(content) > @max_content_length do
      {String.slice(content, 0, @max_content_length), true}
    else
      {content, false}
    end
  end
end
