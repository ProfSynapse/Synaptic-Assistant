# lib/assistant/integrations/google/drive.ex — Google Drive API wrapper.
#
# Thin wrapper around GoogleApi.Drive.V3 that handles Goth authentication
# and normalizes response structs into plain maps. Used by file domain skills
# (files.search, files.read, files.write, files.update, files.archive) and any
# component needing Drive access.
#
# Related files:
#   - lib/assistant/integrations/google/auth.ex (token provider)
#   - lib/assistant/skills/files/search.ex (consumer — files.search skill)
#   - lib/assistant/skills/files/read.ex (consumer — files.read skill)
#   - lib/assistant/skills/files/write.ex (consumer — files.write skill)
#   - lib/assistant/skills/files/update.ex (consumer — files.update skill)
#   - lib/assistant/skills/files/archive.ex (consumer — files.archive skill)

defmodule Assistant.Integrations.Google.Drive do
  @moduledoc """
  Google Drive API client wrapping `GoogleApi.Drive.V3`.

  Provides high-level functions for listing, reading, and creating files
  in Google Drive. Authentication is handled via `Assistant.Integrations.Google.Auth`
  (Goth-based service account tokens).

  All public functions return normalized plain maps rather than GoogleApi structs,
  making them easier to work with in skill handlers and tests.

  ## Usage

      # Search for files
      {:ok, files} = Drive.list_files("name contains 'report'", pageSize: 10)

      # Read file content (auto-detects Google Workspace types)
      {:ok, content} = Drive.read_file("1a2b3c4d")

      # Create a new file
      {:ok, file} = Drive.create_file("notes.txt", "Hello world")

      # Update an existing file's content
      {:ok, file} = Drive.update_file_content("1a2b3c4d", "Updated content")
  """

  require Logger

  alias GoogleApi.Drive.V3.Api.Files
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

    - `query` - Drive search query string (e.g., `"name contains 'report'"`)
    - `opts` - Optional keyword list:
      - `:pageSize` - Max results (default 20, max 1000)
      - `:orderBy` - Sort order (default `"modifiedTime desc"`)
      - `:fields` - Response fields selector

  ## Returns

    - `{:ok, [%{id, name, mime_type, modified_time, size}]}` on success
    - `{:error, term()}` on failure
  """
  @spec list_files(String.t(), keyword()) ::
          {:ok, [map()]} | {:error, term()}
  def list_files(query, opts \\ []) do
    with {:ok, conn} <- get_connection() do
      api_opts =
        [
          q: query,
          pageSize: Keyword.get(opts, :pageSize, 20),
          orderBy: Keyword.get(opts, :orderBy, "modifiedTime desc"),
          fields: Keyword.get(opts, :fields, @default_fields)
        ]
        |> add_opt(:pageToken, Keyword.get(opts, :pageToken))

      case Files.drive_files_list(conn, api_opts) do
        {:ok, %Model.FileList{files: files}} ->
          normalized = Enum.map(files || [], &normalize_file/1)
          {:ok, normalized}

        {:error, reason} ->
          Logger.warning("Drive list_files failed: #{inspect(reason)}")
          {:error, reason}
      end
    end
  end

  @doc """
  Get file metadata by ID.

  ## Returns

    - `{:ok, %{id, name, mime_type, modified_time, size, parents}}` on success
    - `{:error, :not_found | term()}` on failure
  """
  @spec get_file(String.t()) :: {:ok, map()} | {:error, :not_found | term()}
  def get_file(file_id) do
    with {:ok, conn} <- get_connection() do
      case Files.drive_files_get(conn, file_id, fields: @single_file_fields) do
        {:ok, %Model.File{} = file} ->
          {:ok, normalize_file(file)}

        {:error, %Tesla.Env{status: 404}} ->
          {:error, :not_found}

        {:error, reason} ->
          Logger.warning("Drive get_file failed for #{file_id}: #{inspect(reason)}")
          {:error, reason}
      end
    end
  end

  @doc """
  Read file content by ID.

  For Google Workspace files (Docs, Sheets, etc.), exports to the specified
  format (default: `text/plain`). For regular files, downloads the binary content.

  ## Parameters

    - `file_id` - The Drive file ID
    - `opts` - Optional keyword list:
      - `:export_mime_type` - Export format for Workspace files (default `"text/plain"`)

  ## Returns

    - `{:ok, binary()}` on success
    - `{:error, term()}` on failure
  """
  @spec read_file(String.t(), keyword()) :: {:ok, binary()} | {:error, term()}
  def read_file(file_id, opts \\ []) do
    with {:ok, conn} <- get_connection(),
         {:ok, metadata} <- get_file(file_id) do
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

    - `name` - File name
    - `content` - File content as a binary string
    - `opts` - Optional keyword list:
      - `:parent_id` - Parent folder ID
      - `:mime_type` - MIME type (default `"text/plain"`)

  ## Returns

    - `{:ok, %{id, name}}` on success
    - `{:error, term()}` on failure
  """
  @spec create_file(String.t(), binary(), keyword()) :: {:ok, map()} | {:error, term()}
  def create_file(name, content, opts \\ []) do
    with {:ok, conn} <- get_connection() do
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
             fields: "id,name,webViewLink"
           ) do
        {:ok, %Model.File{} = file} ->
          {:ok, %{
            id: file.id,
            name: file.name,
            web_view_link: file.webViewLink
          }}

        {:error, reason} ->
          Logger.warning("Drive create_file failed for #{name}: #{inspect(reason)}")
          {:error, reason}
      end
    end
  end

  @doc """
  Update an existing file's content in Google Drive.

  Uses multipart upload to replace the file's content while preserving
  metadata. For regular files, uploads the content as-is. Google Workspace
  files (Docs, Sheets) cannot have their content replaced via upload —
  those errors are propagated to the caller.

  ## Parameters

    - `file_id` - The Drive file ID to update
    - `content` - New file content as a binary string
    - `mime_type` - MIME type of the content (default `"text/plain"`)

  ## Returns

    - `{:ok, %{id, name, web_view_link}}` on success
    - `{:error, term()}` on failure
  """
  @spec update_file_content(String.t(), binary(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def update_file_content(file_id, content, mime_type \\ "text/plain") do
    with {:ok, conn} <- get_connection() do
      metadata = %Model.File{mimeType: mime_type}

      case Files.drive_files_update_iodata(
             conn,
             file_id,
             "multipart",
             metadata,
             content,
             fields: "id,name,webViewLink"
           ) do
        {:ok, %Model.File{} = file} ->
          {:ok, %{
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

    - `file_id` - The Drive file ID to move
    - `new_parent_id` - The destination folder ID
    - `remove_parents` - Whether to remove existing parents (default `true`).
      When `true`, fetches current parents and removes them so the file
      appears only in the new folder.

  ## Returns

    - `{:ok, %{id, name, parents}}` on success
    - `{:error, term()}` on failure
  """
  @spec move_file(String.t(), String.t(), boolean()) ::
          {:ok, map()} | {:error, term()}
  def move_file(file_id, new_parent_id, remove_parents \\ true) do
    with {:ok, conn} <- get_connection(),
         {:ok, file_meta} <- get_file(file_id) do
      api_opts =
        [addParents: new_parent_id, fields: "id,name,parents"]
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

  # -- Private --

  defp maybe_remove_parents(opts, _file_meta, false), do: opts

  defp maybe_remove_parents(opts, file_meta, true) do
    case file_meta.parents do
      parents when is_list(parents) and parents != [] ->
        Keyword.put(opts, :removeParents, Enum.join(parents, ","))

      _ ->
        opts
    end
  end

  defp get_connection do
    case Assistant.Integrations.Google.Auth.token() do
      {:ok, access_token} ->
        {:ok, Connection.new(access_token)}

      {:error, _reason} = error ->
        error
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
