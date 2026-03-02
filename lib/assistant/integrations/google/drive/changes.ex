# lib/assistant/integrations/google/drive/changes.ex — Google Drive Changes API wrapper.
#
# Wraps the Drive Changes API for incremental sync. Uses `startPageToken`
# cursor to efficiently detect only files modified since the last poll.
# All public functions accept `access_token` as first param, following the
# existing Drive client pattern.
#
# Related files:
#   - lib/assistant/integrations/google/drive.ex (main Drive client)
#   - lib/assistant/schemas/sync_cursor.ex (cursor persistence)
#   - lib/assistant/sync/state_store.ex (CRUD context)

defmodule Assistant.Integrations.Google.Drive.Changes do
  @moduledoc """
  Google Drive Changes API client for incremental file sync.

  Provides functions to get the initial page token and list changes since
  a given token. The Changes API returns only files modified since the last
  poll, making it efficient for periodic sync.

  ## Usage

      # Get initial cursor for a user's personal drive
      {:ok, token} = Changes.get_start_page_token(access_token)

      # Get initial cursor for a shared drive
      {:ok, token} = Changes.get_start_page_token(access_token, drive_id: "0ABcd...")

      # List changes since last poll
      {:ok, result} = Changes.list_changes(access_token, start_page_token)
      # result.changes — list of changed files
      # result.new_start_page_token — cursor for next poll (nil if more pages)
      # result.next_page_token — pagination token (nil if last page)
  """

  require Logger

  alias GoogleApi.Drive.V3.Api.Changes, as: ChangesApi
  alias GoogleApi.Drive.V3.Connection
  alias GoogleApi.Drive.V3.Model

  @changes_fields "changes(fileId,file(id,name,mimeType,modifiedTime,size,parents,trashed),removed,time,changeType),newStartPageToken,nextPageToken"

  @doc """
  Get the starting page token for listing future changes.

  Returns a token that can be used with `list_changes/3` to detect files
  modified after this point in time.

  ## Parameters

    - `access_token` - OAuth2 access token string
    - `opts` - Optional keyword list:
      - `:drive_id` - Shared drive ID (omit for personal drive)

  ## Returns

    - `{:ok, String.t()}` — the start page token
    - `{:error, term()}` on failure
  """
  @spec get_start_page_token(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def get_start_page_token(access_token, opts \\ []) do
    conn = Connection.new(access_token)

    api_opts =
      [supportsAllDrives: true]
      |> add_opt(:driveId, Keyword.get(opts, :drive_id))

    case ChangesApi.drive_changes_get_start_page_token(conn, api_opts) do
      {:ok, %Model.StartPageToken{startPageToken: token}} when is_binary(token) ->
        {:ok, token}

      {:error, reason} ->
        Logger.warning("Drive Changes get_start_page_token failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  List changes since the given page token.

  Returns a list of file changes along with pagination info. If
  `new_start_page_token` is present in the result, it means the end of the
  current change list has been reached and the token should be stored for
  the next poll cycle.

  ## Parameters

    - `access_token` - OAuth2 access token string
    - `page_token` - The token from `get_start_page_token/2` or a previous `list_changes/3` call
    - `opts` - Optional keyword list:
      - `:drive_id` - Shared drive ID (omit for personal drive)
      - `:page_size` - Max changes per page (default 100, max 1000)

  ## Returns

    - `{:ok, %{changes: [map()], new_start_page_token: String.t() | nil, next_page_token: String.t() | nil}}` on success
    - `{:error, term()}` on failure
  """
  @spec list_changes(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def list_changes(access_token, page_token, opts \\ []) do
    conn = Connection.new(access_token)

    api_opts =
      [
        fields: @changes_fields,
        pageSize: Keyword.get(opts, :page_size, 100),
        supportsAllDrives: true,
        includeItemsFromAllDrives: true,
        includeRemoved: true
      ]
      |> add_opt(:driveId, Keyword.get(opts, :drive_id))

    case ChangesApi.drive_changes_list(conn, page_token, api_opts) do
      {:ok, %Model.ChangeList{} = change_list} ->
        {:ok, normalize_change_list(change_list)}

      {:error, reason} ->
        Logger.warning("Drive Changes list_changes failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  List all changes since the given page token, handling pagination automatically.

  Repeatedly calls `list_changes/3` until all pages are consumed. Returns
  the complete list of changes and the new start page token for the next poll.

  ## Parameters

    - `access_token` - OAuth2 access token string
    - `page_token` - The starting page token
    - `opts` - Same options as `list_changes/3`

  ## Returns

    - `{:ok, %{changes: [map()], new_start_page_token: String.t()}}` on success
    - `{:error, term()}` on failure
  """
  @spec list_all_changes(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def list_all_changes(access_token, page_token, opts \\ []) do
    list_all_changes_loop(access_token, page_token, opts, [])
  end

  # -- Private --

  defp list_all_changes_loop(access_token, page_token, opts, acc) do
    case list_changes(access_token, page_token, opts) do
      {:ok, %{changes: changes, new_start_page_token: new_token}} when is_binary(new_token) ->
        {:ok, %{changes: acc ++ changes, new_start_page_token: new_token}}

      {:ok, %{changes: changes, next_page_token: next_token}} when is_binary(next_token) ->
        list_all_changes_loop(access_token, next_token, opts, acc ++ changes)

      {:ok, %{changes: changes}} ->
        # Should not happen — one of the tokens should always be present
        {:ok, %{changes: acc ++ changes, new_start_page_token: page_token}}

      {:error, _} = error ->
        error
    end
  end

  defp normalize_change_list(%Model.ChangeList{} = cl) do
    changes =
      (cl.changes || [])
      |> Enum.filter(&(&1.changeType == "file"))
      |> Enum.map(&normalize_change/1)

    %{
      changes: changes,
      new_start_page_token: cl.newStartPageToken,
      next_page_token: cl.nextPageToken
    }
  end

  defp normalize_change(%Model.Change{} = change) do
    base = %{
      file_id: change.fileId,
      removed: change.removed || false,
      time: change.time
    }

    case change.file do
      %Model.File{} = file ->
        Map.merge(base, %{
          name: file.name,
          mime_type: file.mimeType,
          modified_time: file.modifiedTime,
          size: file.size,
          parents: file.parents,
          trashed: file.trashed || false
        })

      nil ->
        Map.merge(base, %{
          name: nil,
          mime_type: nil,
          modified_time: nil,
          size: nil,
          parents: nil,
          trashed: false
        })
    end
  end

  defp add_opt(opts, _key, nil), do: opts
  defp add_opt(opts, key, value), do: Keyword.put(opts, key, value)
end
