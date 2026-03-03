# lib/assistant/sync/converter.ex — Format conversion for synced Drive files.
#
# Converts Google Drive files into local formats suitable for indexing and
# search. Google Workspace types (Docs, Sheets, Slides) are exported or
# structured into text formats; other files are downloaded as-is.
#
# Related files:
#   - lib/assistant/integrations/google/drive.ex (export/download primitives)
#   - lib/assistant/integrations/google/slides.ex (structured Slides read)
#   - lib/assistant/sync/file_manager.ex (writes converted content to disk)
#   - lib/assistant/sync/workers/sync_poll_worker.ex (consumer)

defmodule Assistant.Sync.Converter do
  @moduledoc """
  Format conversion for Google Drive files.

  Converts Drive files into local text formats for indexing and search.
  Each conversion returns `{:ok, {content_binary, local_format_string}}`
  where `local_format_string` is one of: `"md"`, `"csv"`, `"txt"`, `"json"`.

  ## Conversion Rules

    * Google Docs → Markdown export (`"md"`)
    * Google Sheets → CSV export (`"csv"`)
    * Google Slides → Structured Markdown via Slides API (`"md"`)
    * Other files → Raw binary download, format derived from MIME type

  All functions accept `access_token` as the first parameter, following the
  existing Google integration pattern.
  """

  require Logger

  alias Assistant.Integrations.Google.Drive
  alias Assistant.Integrations.Google.Slides

  alias GoogleApi.Drive.V3.Api.Files
  alias GoogleApi.Drive.V3.Connection

  @doc """
  Convert a Drive file to a local format.

  ## Parameters

    - `access_token` - OAuth2 access token string
    - `drive_file_id` - The Drive file ID
    - `mime_type` - The file's MIME type (determines conversion strategy)
    - `opts` - Optional keyword list (reserved for future use)

  ## Returns

    - `{:ok, {content :: binary(), format :: String.t()}}` on success
    - `{:error, term()}` on failure
  """
  @spec convert(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, {binary(), String.t()}} | {:error, term()}
  def convert(access_token, drive_file_id, mime_type, opts \\ [])

  def convert(access_token, drive_file_id, "application/vnd.google-apps.document", _opts) do
    convert_doc(access_token, drive_file_id)
  end

  def convert(access_token, drive_file_id, "application/vnd.google-apps.spreadsheet", _opts) do
    convert_sheet(access_token, drive_file_id)
  end

  def convert(access_token, drive_file_id, "application/vnd.google-apps.presentation", _opts) do
    convert_slides(access_token, drive_file_id)
  end

  def convert(access_token, drive_file_id, mime_type, _opts) do
    if Drive.google_workspace_type?(mime_type) do
      # Unknown Google Workspace type — export as plain text
      convert_generic_workspace(access_token, drive_file_id)
    else
      download_raw(access_token, drive_file_id, mime_type)
    end
  end

  # -- Private Converters --

  # Google Docs → Markdown via Drive export API
  defp convert_doc(access_token, file_id) do
    conn = Connection.new(access_token)

    case export_file(conn, file_id, "text/markdown") do
      {:ok, content} ->
        {:ok, {content, "md"}}

      {:error, _} ->
        Logger.warning(
          "Converter: Docs markdown export failed for #{file_id}, falling back to plain text"
        )

        case export_file(conn, file_id, "text/plain") do
          {:ok, content} -> {:ok, {content, "txt"}}
          {:error, _} = fallback_error -> fallback_error
        end
    end
  end

  # Google Sheets → CSV via Drive export API
  defp convert_sheet(access_token, file_id) do
    conn = Connection.new(access_token)

    case export_file(conn, file_id, "text/csv") do
      {:ok, content} -> {:ok, {content, "csv"}}
      {:error, _} = error -> error
    end
  end

  # Google Slides → Structured Markdown via Slides API
  defp convert_slides(access_token, file_id) do
    case Slides.get_presentation(access_token, file_id) do
      {:ok, presentation} ->
        markdown = format_presentation_as_markdown(presentation)
        {:ok, {markdown, "md"}}

      {:error, _} = error ->
        error
    end
  end

  # Unknown Google Workspace type → plain text export
  defp convert_generic_workspace(access_token, file_id) do
    conn = Connection.new(access_token)

    case export_file(conn, file_id, "text/plain") do
      {:ok, content} -> {:ok, {content, "txt"}}
      {:error, _} = error -> error
    end
  end

  # Non-Google binary file → raw download
  defp download_raw(access_token, file_id, mime_type) do
    conn = Connection.new(access_token)

    case download_file(conn, file_id) do
      {:ok, content} ->
        format = format_from_mime(mime_type)
        {:ok, {content, format}}

      {:error, _} = error ->
        error
    end
  end

  # -- Drive API Helpers --
  # Follow the same export/download pattern as drive.ex

  defp export_file(conn, file_id, export_mime_type) do
    case Files.drive_files_export(conn, file_id, export_mime_type, alt: "media") do
      {:ok, %Tesla.Env{body: body}} when is_binary(body) ->
        {:ok, body}

      {:ok, body} when is_binary(body) ->
        {:ok, body}

      {:ok, nil} ->
        {:ok, ""}

      {:error, reason} ->
        Logger.warning("Converter: export failed for #{file_id}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp download_file(conn, file_id) do
    case Files.drive_files_get(conn, file_id, alt: "media") do
      {:ok, %Tesla.Env{body: body}} when is_binary(body) ->
        {:ok, body}

      {:ok, body} when is_binary(body) ->
        {:ok, body}

      {:error, reason} ->
        Logger.warning("Converter: download failed for #{file_id}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # -- Slides Markdown Formatting --

  defp format_presentation_as_markdown(presentation) do
    title_line = "# #{presentation.title}\n\n"

    slides_content =
      presentation.slides
      |> Enum.map(&format_slide/1)
      |> Enum.join("\n\n")

    title_line <> slides_content
  end

  defp format_slide(slide) do
    heading = "## Slide #{slide.slide_number}"

    text_items =
      (slide.text_content || [])
      |> Enum.map(fn text -> "- #{String.trim(text)}" end)

    body =
      case text_items do
        [] -> "_[No text content]_"
        items -> Enum.join(items, "\n")
      end

    heading <> "\n\n" <> body
  end

  # -- MIME → Format Mapping --

  @mime_to_format %{
    "text/plain" => "txt",
    "text/markdown" => "md",
    "text/csv" => "csv",
    "text/html" => "txt",
    "application/json" => "json",
    "application/pdf" => "txt"
  }

  defp format_from_mime(mime_type) do
    case Map.get(@mime_to_format, mime_type) do
      nil ->
        if String.starts_with?(mime_type, "text/"), do: "txt", else: "bin"

      format ->
        format
    end
  end
end
