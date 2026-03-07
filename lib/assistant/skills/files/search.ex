# lib/assistant/skills/files/search.ex — Handler for files.search skill.
#
# Searches the local SyncedFile database for matched files.
# Supports text query (matching file name or local path),
# MIME type filtering, folder scoping (via path matching), and result limiting.
#
# Related files:
#   - lib/assistant/skills/handler.ex (behaviour)
#   - priv/skills/files/search.md (skill definition)

defmodule Assistant.Skills.Files.Search do
  @moduledoc """
  Skill handler for searching synced files in the workspace.

  Builds a local database query from CLI flags (query text, type, folder) and returns
  a formatted list of matching files for LLM context.
  """

  @behaviour Assistant.Skills.Handler

  import Ecto.Query
  alias Assistant.Repo
  alias Assistant.Schemas.SyncedFile
  alias Assistant.Skills.Helpers, as: SkillsHelpers
  alias Assistant.Skills.Result

  @type_to_mime %{
    "doc" => "application/vnd.google-apps.document",
    "document" => "application/vnd.google-apps.document",
    "sheet" => "application/vnd.google-apps.spreadsheet",
    "spreadsheet" => "application/vnd.google-apps.spreadsheet",
    "slides" => "application/vnd.google-apps.presentation",
    "presentation" => "application/vnd.google-apps.presentation",
    "pdf" => "application/pdf",
    "folder" => "application/vnd.google-apps.folder",
    "image" => "image/",
    "video" => "video/"
  }

  @default_limit 20
  @max_limit 100

  @impl true
  def execute(flags, context) do
    # Google token is not strictly necessary for local search, but to keep semantics 
    # similar, we make sure they connected at least a user_id
    user_id = context.user_id

    if is_nil(user_id) do
      {:ok, %Result{status: :error, content: "User context is required to search files."}}
    else
      do_execute(flags, user_id)
    end
  end

  defp do_execute(flags, user_id) do
    query_text = Map.get(flags, "query")
    type = Map.get(flags, "type")
    folder = Map.get(flags, "folder")
    limit = SkillsHelpers.parse_limit(Map.get(flags, "limit"), @default_limit, @max_limit)

    with :ok <- validate_type(type) do
      files = search_files_local(user_id, query_text, type, folder, limit)

      if Enum.empty?(files) do
        {:ok,
         %Result{
           status: :ok,
           content: "No files found matching the given criteria.",
           metadata: %{count: 0}
         }}
      else
        content = format_file_list(files)

        {:ok,
         %Result{
           status: :ok,
           content: content,
           metadata: %{count: length(files)}
         }}
      end
    end
  rescue
    e in _ ->
      {:ok,
       %Result{
         status: :error,
         content: "Local search failed: #{Exception.message(e)}"
       }}
  end

  defp validate_type(nil), do: :ok

  defp validate_type(type) do
    case resolve_type(type) do
      {:ok, _mime} -> :ok
      {:error, message} -> {:ok, %Result{status: :error, content: message}}
    end
  end

  defp search_files_local(user_id, query_text, type, folder, limit) do
    base_query =
      from s in SyncedFile,
        where: s.user_id == ^user_id,
        where: s.sync_status != "error",
        limit: ^limit,
        order_by: [desc: s.last_synced_at]

    base_query
    |> apply_query_text(query_text)
    |> apply_type(type)
    |> apply_folder(folder)
    |> Repo.all()
  end

  defp apply_query_text(query, nil), do: query

  defp apply_query_text(query, text) do
    search_term = "%#{text}%"

    from s in query,
      where: ilike(s.drive_file_name, ^search_term) or ilike(s.local_path, ^search_term)
  end

  defp apply_type(query, nil), do: query

  defp apply_type(query, type) do
    case resolve_type(type) do
      {:ok, mime} ->
        from s in query, where: s.drive_mime_type == ^mime

      _ ->
        # Ignore invalid types or just skip
        query
    end
  end

  defp apply_folder(query, nil), do: query

  defp apply_folder(query, folder) do
    # Assuming folder is either an ID or path segment
    # For now, we search within local_path if a folder is specified
    search_term = "%#{folder}%"
    from s in query, where: ilike(s.local_path, ^search_term)
  end

  defp resolve_type(nil), do: :skip

  defp resolve_type(type) do
    case Map.fetch(@type_to_mime, String.downcase(type)) do
      {:ok, mime} ->
        {:ok, mime}

      :error ->
        {:error,
         "Unknown file type '#{type}'. Supported: doc, sheet, slides, pdf, folder, image, video."}
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
    type_label = friendly_type(file.drive_mime_type)

    synced =
      if file.last_synced_at, do: " | Last Synced: #{format_time(file.last_synced_at)}", else: ""

    path_str = if file.local_path, do: " | Local Path: #{file.local_path}", else: ""

    "- [#{file.drive_file_id}] #{file.drive_file_name} (#{type_label})#{path_str}#{synced}"
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
end
