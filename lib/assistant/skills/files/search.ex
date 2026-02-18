# lib/assistant/skills/files/search.ex — Handler for files.search skill.
#
# Searches Google Drive files using the Drive API wrapper. Supports text query,
# MIME type filtering, folder scoping, and result limiting.
#
# Related files:
#   - lib/assistant/integrations/google/drive.ex (Drive API client)
#   - lib/assistant/skills/handler.ex (behaviour)
#   - priv/skills/files/search.md (skill definition)

defmodule Assistant.Skills.Files.Search do
  @moduledoc """
  Skill handler for searching Google Drive files.

  Builds a Drive query from CLI flags (query text, type, folder) and returns
  a formatted list of matching files for LLM context.
  """

  @behaviour Assistant.Skills.Handler

  alias Assistant.Skills.Result
  alias Assistant.Integrations.Google.Drive

  @default_limit 20
  @max_limit 100

  @impl true
  def execute(flags, context) do
    drive = Map.get(context.integrations, :drive, Drive)

    query = Map.get(flags, "query")
    type = Map.get(flags, "type")
    folder = Map.get(flags, "folder")
    limit = parse_limit(Map.get(flags, "limit"))

    case build_query(query, type, folder) do
      {:ok, q} ->
        search_files(drive, q, limit)

      {:error, reason} ->
        {:ok, %Result{status: :error, content: reason}}
    end
  end

  defp search_files(drive, query, limit) do
    case drive.list_files(query, pageSize: limit) do
      {:ok, []} ->
        {:ok, %Result{
          status: :ok,
          content: "No files found matching the given criteria.",
          metadata: %{count: 0}
        }}

      {:ok, files} ->
        content = format_file_list(files)

        {:ok, %Result{
          status: :ok,
          content: content,
          metadata: %{count: length(files)}
        }}

      {:error, reason} ->
        {:ok, %Result{
          status: :error,
          content: "Drive search failed: #{inspect(reason)}"
        }}
    end
  end

  defp build_query(nil, nil, nil) do
    {:ok, "trashed = false"}
  end

  defp build_query(query, type, folder) do
    parts = ["trashed = false"]

    parts =
      if query do
        [~s(name contains '#{escape_query(query)}') | parts]
      else
        parts
      end

    parts =
      case resolve_type(type) do
        {:ok, mime} -> [~s(mimeType = '#{mime}') | parts]
        :skip -> parts
        {:error, _} = err -> throw(err)
      end

    parts =
      if folder do
        [~s('#{escape_query(folder)}' in parents) | parts]
      else
        parts
      end

    {:ok, Enum.join(Enum.reverse(parts), " and ")}
  catch
    {:error, reason} -> {:error, reason}
  end

  defp resolve_type(nil), do: :skip

  defp resolve_type(type) do
    case Drive.type_to_mime(type) do
      {:ok, mime} -> {:ok, mime}
      :error -> {:error, "Unknown file type '#{type}'. Supported: doc, sheet, slides, pdf, folder, image, video."}
    end
  end

  defp format_file_list(files) do
    header = "Found #{length(files)} file(s):\n"

    rows =
      files
      |> Enum.map(&format_file_row/1)
      |> Enum.join("\n")

    header <> rows
  end

  defp format_file_row(file) do
    type_label = friendly_type(file.mime_type)
    modified = if file.modified_time, do: " | Modified: #{format_time(file.modified_time)}", else: ""
    size_str = if file.size, do: " | Size: #{format_size(file.size)}", else: ""

    "- [#{file.id}] #{file.name} (#{type_label})#{modified}#{size_str}"
  end

  defp friendly_type("application/vnd.google-apps.document"), do: "Google Doc"
  defp friendly_type("application/vnd.google-apps.spreadsheet"), do: "Google Sheet"
  defp friendly_type("application/vnd.google-apps.presentation"), do: "Google Slides"
  defp friendly_type("application/vnd.google-apps.folder"), do: "Folder"
  defp friendly_type("application/pdf"), do: "PDF"
  defp friendly_type(mime) when is_binary(mime), do: mime
  defp friendly_type(_), do: "Unknown"

  defp format_time(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M")
  defp format_time(time) when is_binary(time), do: time
  defp format_time(_), do: ""

  defp format_size(size) when is_binary(size) do
    case Integer.parse(size) do
      {bytes, _} -> format_bytes(bytes)
      :error -> size
    end
  end

  defp format_size(size) when is_integer(size), do: format_bytes(size)
  defp format_size(_), do: ""

  defp format_bytes(bytes) when bytes < 1024, do: "#{bytes} B"
  defp format_bytes(bytes) when bytes < 1_048_576, do: "#{Float.round(bytes / 1024, 1)} KB"
  defp format_bytes(bytes), do: "#{Float.round(bytes / 1_048_576, 1)} MB"

  defp parse_limit(nil), do: @default_limit

  defp parse_limit(limit) when is_binary(limit) do
    case Integer.parse(limit) do
      {n, _} -> min(max(n, 1), @max_limit)
      :error -> @default_limit
    end
  end

  defp parse_limit(limit) when is_integer(limit), do: min(max(limit, 1), @max_limit)
  defp parse_limit(_), do: @default_limit

  defp escape_query(str) do
    String.replace(str, "'", "\\'")
  end
end
