# lib/assistant/integrations/google/drive.ex — Google Drive API wrapper.
#
# Thin wrapper around GoogleApi.Drive.V3 that normalizes response structs
# into plain maps. All public functions accept an `access_token` as first
# parameter (per-user OAuth or service-account) to create a Tesla connection.
#
# Related files:
#   - lib/assistant/integrations/google/auth.ex (token provider)
#   - lib/assistant/integrations/google/drive/scoping.ex (query param builder)
#   - lib/assistant/skills/files/search.ex (consumer — files.search skill)
#   - lib/assistant/skills/files/read.ex (consumer — files.read skill)
#   - lib/assistant/skills/files/write.ex (consumer — files.write skill)
#   - lib/assistant/skills/files/update.ex (consumer — files.update skill)
#   - lib/assistant/skills/files/archive.ex (consumer — files.archive skill)

defmodule Assistant.Integrations.Google.Drive do
  @moduledoc """
  Google Drive API client wrapping `GoogleApi.Drive.V3`.

  Provides high-level functions for listing, reading, creating, and updating
  files in Google Drive. All public functions that make API calls accept an
  `access_token` string as the first parameter.

  All public functions return normalized plain maps rather than GoogleApi structs,
  making them easier to work with in skill handlers and tests.

  ## Usage

      # Search for files
      {:ok, files} = Drive.list_files(token, "name contains 'report'", pageSize: 10)

      # Read file content (auto-detects Google Workspace types)
      {:ok, content} = Drive.read_file(token, "1a2b3c4d")

      # Create a new file
      {:ok, file} = Drive.create_file(token, "notes.txt", "Hello world")

      # Update an existing file's content
      {:ok, file} = Drive.update_file_content(token, "1a2b3c4d", "Updated content")

      # List shared drives
      {:ok, drives} = Drive.list_shared_drives(token)
  """

  require Logger

  alias GoogleApi.Drive.V3.Api.{Drives, Files}
  alias GoogleApi.Drive.V3.Connection
  alias GoogleApi.Drive.V3.Model

  @default_fields "files(id,name,mimeType,modifiedTime,size,parents)"
  @single_file_fields "id,name,mimeType,modifiedTime,size,parents,webViewLink"

  @google_workspace_prefix "application/vnd.google-apps."

  # MIME type mapping for --type flag in files.search
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

  @doc """
  List files matching a Drive search query.

  ## Parameters

    - `access_token` - OAuth2 access token string
    - `query` - Drive search query string (e.g., `"name contains 'report'"`)
    - `opts` - Optional keyword list:
      - `:pageSize` - Max results (default 20, max 1000)
      - `:orderBy` - Sort order (default `"modifiedTime desc"`)
      - `:fields` - Response fields selector
      - `:corpora` - Search scope (`"user"`, `"drive"`, `"allDrives"`)
      - `:driveId` - Specific shared drive ID (when corpora is `"drive"`)
      - `:includeItemsFromAllDrives` - Include shared drive items
      - `:supportsAllDrives` - Indicate shared drive support

  ## Returns

    - `{:ok, [%{id, name, mime_type, modified_time, size}]}` on success
    - `{:error, term()}` on failure
  """
  @spec list_files(String.t(), String.t(), keyword()) ::
          {:ok, [map()]} | {:error, term()}
  def list_files(access_token, query, opts \\ []) do
    conn = Connection.new(access_token)

    api_opts =
      [
        q: query,
        pageSize: Keyword.get(opts, :pageSize, 20),
        orderBy: Keyword.get(opts, :orderBy, "modifiedTime desc"),
        fields: Keyword.get(opts, :fields, @default_fields)
      ]
      |> add_opt(:pageToken, Keyword.get(opts, :pageToken))
      |> add_opt(:corpora, Keyword.get(opts, :corpora))
      |> add_opt(:driveId, Keyword.get(opts, :driveId))
      |> add_opt(:includeItemsFromAllDrives, Keyword.get(opts, :includeItemsFromAllDrives))
      |> add_opt(:supportsAllDrives, Keyword.get(opts, :supportsAllDrives))

    case Files.drive_files_list(conn, api_opts) do
      {:ok, %Model.FileList{files: files}} ->
        normalized = Enum.map(files || [], &normalize_file/1)
        {:ok, normalized}

      {:error, reason} ->
        Logger.warning("Drive list_files failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Get file metadata by ID.

  ## Parameters

    - `access_token` - OAuth2 access token string
    - `file_id` - The Drive file ID

  ## Returns

    - `{:ok, %{id, name, mime_type, modified_time, size, parents}}` on success
    - `{:error, :not_found | term()}` on failure
  """
  @spec get_file(String.t(), String.t()) :: {:ok, map()} | {:error, :not_found | term()}
  def get_file(access_token, file_id) do
    conn = Connection.new(access_token)

    case Files.drive_files_get(conn, file_id,
           fields: @single_file_fields,
           supportsAllDrives: true
         ) do
      {:ok, %Model.File{} = file} ->
        {:ok, normalize_file(file)}

      {:error, %Tesla.Env{status: 404}} ->
        {:error, :not_found}

      {:error, reason} ->
        Logger.warning("Drive get_file failed for #{file_id}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Read file content by ID.

  For Google Workspace files (Docs, Sheets, etc.), exports to the specified
  format (default: `text/plain`). For regular files, downloads the binary content.

  ## Parameters

    - `access_token` - OAuth2 access token string
    - `file_id` - The Drive file ID
    - `opts` - Optional keyword list:
      - `:export_mime_type` - Export format for Workspace files (default `"text/plain"`)

  ## Returns

    - `{:ok, binary()}` on success
    - `{:error, term()}` on failure
  """
  @spec read_file(String.t(), String.t(), keyword()) :: {:ok, binary()} | {:error, term()}
  def read_file(access_token, file_id, opts \\ []) do
    conn = Connection.new(access_token)

    with {:ok, metadata} <- get_file(access_token, file_id) do
      if google_workspace_type?(metadata.mime_type) do
        export_mime = Keyword.get(opts, :export_mime_type, "text/plain")
        export_file(conn, file_id, export_mime)
      else
        download_file(conn, file_id)
      end
    end
  end

  @doc """
  Check if a MIME type is a Google Workspace type (requiring export instead of download).

  Google Workspace types follow the pattern `application/vnd.google-apps.*`.
  """
  @spec google_workspace_type?(String.t()) :: boolean()
  def google_workspace_type?(mime_type) when is_binary(mime_type) do
    String.starts_with?(mime_type, @google_workspace_prefix)
  end

  def google_workspace_type?(_), do: false

  @doc """
  Create a new file in Google Drive.

  ## Parameters

    - `access_token` - OAuth2 access token string
    - `name` - File name
    - `content` - File content as a binary string
    - `opts` - Optional keyword list:
      - `:parent_id` - Parent folder ID
      - `:mime_type` - MIME type (default `"text/plain"`)

  ## Returns

    - `{:ok, %{id, name}}` on success
    - `{:error, term()}` on failure
  """
  @spec create_file(String.t(), String.t(), binary(), keyword()) :: {:ok, map()} | {:error, term()}
  def create_file(access_token, name, content, opts \\ []) do
    conn = Connection.new(access_token)
    mime_type = Keyword.get(opts, :mime_type, "text/plain")
    parent_id = Keyword.get(opts, :parent_id)

    metadata = %Model.File{
      name: name,
      mimeType: mime_type,
      parents: if(parent_id, do: [parent_id], else: nil)
    }

    case Files.drive_files_create_iodata(
           conn,
           "multipart",
           metadata,
           content,
           fields: "id,name,webViewLink",
           supportsAllDrives: true
         ) do
      {:ok, %Model.File{} = file} ->
        {:ok,
         %{
           id: file.id,
           name: file.name,
           web_view_link: file.webViewLink
         }}

      {:error, reason} ->
        Logger.warning("Drive create_file failed for #{name}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Update an existing file's content in Google Drive.

  Uses multipart upload to replace the file's content while preserving
  metadata. For regular files, uploads the content as-is. Google Workspace
  files (Docs, Sheets) cannot have their content replaced via upload —
  those errors are propagated to the caller.

  ## Parameters

    - `access_token` - OAuth2 access token string
    - `file_id` - The Drive file ID to update
    - `content` - New file content as a binary string
    - `mime_type` - MIME type of the content (default `"text/plain"`)

  ## Returns

    - `{:ok, %{id, name, web_view_link}}` on success
    - `{:error, term()}` on failure
  """
  @spec update_file_content(String.t(), String.t(), binary(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def update_file_content(access_token, file_id, content, mime_type \\ "text/plain") do
    conn = Connection.new(access_token)
    metadata = %Model.File{mimeType: mime_type}

    case Files.drive_files_update_iodata(
           conn,
           file_id,
           "multipart",
           metadata,
           content,
           fields: "id,name,webViewLink",
           supportsAllDrives: true
         ) do
      {:ok, %Model.File{} = file} ->
        {:ok,
         %{
           id: file.id,
           name: file.name,
           web_view_link: file.webViewLink
         }}

      {:error, %Tesla.Env{status: 404}} ->
        {:error, :not_found}

      {:error, reason} ->
        Logger.warning("Drive update_file_content failed for #{file_id}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Map a user-friendly type string to a Google Drive MIME type.

  Used by the files.search skill to translate `--type doc` into the
  appropriate MIME type filter.

  ## Examples

      iex> Drive.type_to_mime("doc")
      {:ok, "application/vnd.google-apps.document"}

      iex> Drive.type_to_mime("unknown")
      :error
  """
  @spec type_to_mime(String.t()) :: {:ok, String.t()} | :error
  def type_to_mime(type) when is_binary(type) do
    case Map.fetch(@type_to_mime, String.downcase(type)) do
      {:ok, mime} -> {:ok, mime}
      :error -> :error
    end
  end

  @doc """
  Move a file to a new parent folder.

  Uses the Drive Files.update endpoint with `addParents` / `removeParents`
  query parameters to re-parent a file without changing its content.

  ## Parameters

    - `access_token` - OAuth2 access token string
    - `file_id` - The Drive file ID to move
    - `new_parent_id` - The destination folder ID
    - `remove_parents` - Whether to remove existing parents (default `true`).
      When `true`, fetches current parents and removes them so the file
      appears only in the new folder.

  ## Returns

    - `{:ok, %{id, name, parents}}` on success
    - `{:error, term()}` on failure
  """
  @spec move_file(String.t(), String.t(), String.t(), boolean()) ::
          {:ok, map()} | {:error, term()}
  def move_file(access_token, file_id, new_parent_id, remove_parents \\ true) do
    conn = Connection.new(access_token)

    with {:ok, file_meta} <- get_file(access_token, file_id) do
      api_opts =
        [addParents: new_parent_id, fields: "id,name,parents", supportsAllDrives: true]
        |> maybe_remove_parents(file_meta, remove_parents)

      case Files.drive_files_update(conn, file_id, api_opts) do
        {:ok, %Model.File{} = updated} ->
          {:ok, %{id: updated.id, name: updated.name, parents: updated.parents}}

        {:error, reason} ->
          Logger.warning("Drive move_file failed for #{file_id}: #{inspect(reason)}")
          {:error, reason}
      end
    end
  end

  @doc """
  List shared drives accessible to the authenticated user.

  Returns a flat list of shared drives with their IDs and names.
  Paginates automatically to return all results.

  ## Parameters

    - `access_token` - OAuth2 access token string

  ## Returns

    - `{:ok, [%{id: String.t(), name: String.t()}]}` on success
    - `{:error, term()}` on failure
  """
  @spec list_shared_drives(String.t()) :: {:ok, [map()]} | {:error, term()}
  def list_shared_drives(access_token) do
    conn = Connection.new(access_token)
    list_shared_drives_page(conn, nil, [])
  end

  # -- Private --

  defp list_shared_drives_page(conn, page_token, acc) do
    opts =
      [pageSize: 100, fields: "drives(id,name),nextPageToken"]
      |> add_opt(:pageToken, page_token)

    case Drives.drive_drives_list(conn, opts) do
      {:ok, %{drives: drives, nextPageToken: next_token}} ->
        normalized =
          (drives || [])
          |> Enum.map(fn d -> %{id: d.id, name: d.name} end)

        all = acc ++ normalized

        if next_token do
          list_shared_drives_page(conn, next_token, all)
        else
          {:ok, all}
        end

      {:error, reason} ->
        Logger.warning("Drive list_shared_drives failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp maybe_remove_parents(opts, _file_meta, false), do: opts

  defp maybe_remove_parents(opts, file_meta, true) do
    case file_meta.parents do
      parents when is_list(parents) and parents != [] ->
        Keyword.put(opts, :removeParents, Enum.join(parents, ","))

      _ ->
        opts
    end
  end

  defp export_file(conn, file_id, export_mime_type) do
    case Files.drive_files_export(conn, file_id, export_mime_type, alt: "media") do
      {:ok, %Tesla.Env{body: body}} when is_binary(body) ->
        {:ok, body}

      {:ok, body} when is_binary(body) ->
        {:ok, body}

      {:ok, nil} ->
        {:ok, ""}

      {:error, reason} ->
        Logger.warning("Drive export failed for #{file_id}: #{inspect(reason)}")
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
        Logger.warning("Drive download failed for #{file_id}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp normalize_file(%Model.File{} = file) do
    %{
      id: file.id,
      name: file.name,
      mime_type: file.mimeType,
      modified_time: file.modifiedTime,
      size: file.size,
      parents: file.parents,
      web_view_link: file.webViewLink
    }
  end

  defp normalize_file(nil), do: nil

  defp add_opt(opts, _key, nil), do: opts
  defp add_opt(opts, key, value), do: Keyword.put(opts, key, value)
end
