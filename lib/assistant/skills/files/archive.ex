# lib/assistant/skills/files/archive.ex — Handler for files.archive skill.
#
# Moves a file into an Archive folder in Google Drive. If no specific
# archive folder is provided, searches for (or creates) a root-level
# folder named "Archive".
#
# Related files:
#   - lib/assistant/integrations/google/drive.ex (Drive API client — move_file/3)
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
  alias Assistant.Integrations.Google.Drive

  @archive_folder_name "Archive"
  @folder_mime_type "application/vnd.google-apps.folder"

  @impl true
  def execute(flags, context) do
    drive = Map.get(context.integrations, :drive, Drive)
    file_id = Map.get(flags, "id")
    folder_id = Map.get(flags, "folder")

    cond do
      is_nil(file_id) || file_id == "" ->
        {:ok, %Result{status: :error, content: "Missing required parameter: --id (file ID)."}}

      true ->
        archive_file(drive, file_id, folder_id)
    end
  end

  defp archive_file(drive, file_id, folder_id) do
    with {:ok, archive_id} <- resolve_archive_folder(drive, folder_id),
         {:ok, file_meta} <- drive.get_file(file_id),
         {:ok, _moved} <- drive.move_file(file_id, archive_id) do
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

      {:error, reason} ->
        {:ok, %Result{status: :error, content: "Failed to archive file: #{inspect(reason)}"}}
    end
  end

  defp resolve_archive_folder(_drive, folder_id) when is_binary(folder_id) and folder_id != "" do
    {:ok, folder_id}
  end

  defp resolve_archive_folder(drive, _folder_id) do
    query =
      "name = '#{@archive_folder_name}' and mimeType = '#{@folder_mime_type}' and trashed = false"

    case drive.list_files(query, pageSize: 1) do
      {:ok, [%{id: id} | _]} ->
        {:ok, id}

      {:ok, []} ->
        create_archive_folder(drive)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp create_archive_folder(drive) do
    case drive.create_file(@archive_folder_name, "", mime_type: @folder_mime_type) do
      {:ok, %{id: id}} -> {:ok, id}
      {:error, reason} -> {:error, reason}
    end
  end
end
