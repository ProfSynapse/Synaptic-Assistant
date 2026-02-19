# lib/assistant/skills/files/read.ex — Handler for files.read skill.
#
# Reads a Google Drive file's content by ID. For Google Workspace files
# (Docs, Sheets, etc.), exports to text/plain. For regular files, downloads
# the binary content. Truncates at 8000 chars to preserve LLM context.
#
# Related files:
#   - lib/assistant/integrations/google/drive.ex (Drive API client)
#   - lib/assistant/skills/handler.ex (behaviour)
#   - priv/skills/files/read.md (skill definition)

defmodule Assistant.Skills.Files.Read do
  @moduledoc """
  Skill handler for reading Google Drive file content.

  Fetches file metadata first to determine the file type, then either
  exports (Google Workspace) or downloads (regular files) the content.
  Output is truncated at 8000 characters to protect LLM context budgets.
  """

  @behaviour Assistant.Skills.Handler

  alias Assistant.Skills.Result
  alias Assistant.Integrations.Google.Drive

  @max_content_length 8_000

  @impl true
  def execute(flags, context) do
    drive = Map.get(context.integrations, :drive, Drive)
    file_id = Map.get(flags, "id")
    format = Map.get(flags, "format")

    cond do
      is_nil(file_id) || file_id == "" ->
        {:ok, %Result{status: :error, content: "Missing required parameter: --id (file ID)."}}

      true ->
        read_and_format(drive, file_id, format)
    end
  end

  defp read_and_format(drive, file_id, format) do
    opts = if format, do: [export_mime_type: format], else: []

    case drive.read_file(file_id, opts) do
      {:ok, content} when is_binary(content) ->
        {display_content, truncated?} = maybe_truncate(content)

        header = build_header(drive, file_id)
        truncation_note = if truncated?, do: "\n\n...content truncated at #{@max_content_length} characters. Full file available in Drive.", else: ""

        {:ok, %Result{
          status: :ok,
          content: header <> display_content <> truncation_note,
          metadata: %{
            file_id: file_id,
            content_length: byte_size(content),
            truncated: truncated?
          }
        }}

      {:error, :not_found} ->
        {:ok, %Result{
          status: :error,
          content: "File not found: #{file_id}. Check the file ID and ensure the service account has access."
        }}

      {:error, reason} ->
        {:ok, %Result{
          status: :error,
          content: "Failed to read file #{file_id}: #{inspect(reason)}"
        }}
    end
  end

  defp build_header(drive, file_id) do
    case drive.get_file(file_id) do
      {:ok, metadata} ->
        type_label = if Drive.google_workspace_type?(metadata.mime_type), do: " (exported as text)", else: ""
        "## #{metadata.name}#{type_label}\n\n"

      {:error, _} ->
        ""
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
