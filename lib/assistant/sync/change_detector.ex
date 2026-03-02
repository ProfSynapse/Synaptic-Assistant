# lib/assistant/sync/change_detector.ex — Conflict detection for file sync.
#
# Pure functions that compare local sync state against remote Drive changes
# to detect updates and conflicts. No side effects — all state is passed in,
# decisions are returned as atoms.
#
# Related files:
#   - lib/assistant/schemas/synced_file.ex (local sync record)
#   - lib/assistant/sync/file_manager.ex (local file checksums)
#   - lib/assistant/sync/workers/sync_poll_worker.ex (consumer)

defmodule Assistant.Sync.ChangeDetector do
  @moduledoc """
  Conflict detection for the file sync engine.

  Pure functions that compare local sync state (from `SyncedFile` records)
  against remote Drive changes to determine what action is needed.

  ## Decision Table

  | Local State       | Remote Changed? | Local Modified? | Result            |
  |-------------------|-----------------|-----------------|-------------------|
  | nil (new file)    | yes             | n/a             | `:remote_updated` |
  | exists            | yes             | no              | `:remote_updated` |
  | exists            | yes             | yes             | `:conflict`       |
  | exists            | no              | n/a             | `:no_conflict`    |

  Local modification is detected by comparing the stored `local_checksum`
  against the current content checksum.
  """

  alias Assistant.Schemas.SyncedFile

  @type conflict_result :: :no_conflict | :remote_updated | :conflict

  @doc """
  Detect the conflict state between a local synced file and a remote change.

  ## Parameters

    - `synced_file` - The existing `%SyncedFile{}` record, or `nil` for new files
    - `remote_change` - A normalized change map from `Drive.Changes` with at least:
      - `:modified_time` — remote file modification time (DateTime string or nil)
      - `:removed` — whether the file was deleted remotely

  ## Returns

    - `:remote_updated` — remote has a newer version, safe to overwrite local
    - `:conflict` — both local and remote were modified since last sync
    - `:no_conflict` — no changes detected
  """
  @spec detect_conflict(SyncedFile.t() | nil, map()) :: conflict_result()
  def detect_conflict(nil, _remote_change), do: :remote_updated

  def detect_conflict(%SyncedFile{} = synced_file, remote_change) do
    remote_modified = parse_remote_time(remote_change.modified_time)
    local_synced_at = synced_file.remote_modified_at

    cond do
      # Remote file was removed/trashed — always counts as remote update
      remote_change[:removed] == true ->
        :remote_updated

      # No remote modification time to compare — treat as updated
      is_nil(remote_modified) ->
        :remote_updated

      # Remote is newer than what we have
      remote_is_newer?(remote_modified, local_synced_at) ->
        if local_was_modified?(synced_file) do
          :conflict
        else
          :remote_updated
        end

      # Remote hasn't changed
      true ->
        :no_conflict
    end
  end

  @doc """
  Generate a conflict file path by appending a timestamp before the extension.

  ## Examples

      iex> ChangeDetector.generate_conflict_path("notes.md")
      "notes.conflict.20260302T120000Z.md"

      iex> ChangeDetector.generate_conflict_path("data")
      "data.conflict.20260302T120000Z"
  """
  @spec generate_conflict_path(String.t()) :: String.t()
  def generate_conflict_path(original_path) do
    timestamp = format_timestamp(DateTime.utc_now())
    ext = Path.extname(original_path)
    base = Path.rootname(original_path)
    suffix = ".conflict.#{timestamp}"

    if ext == "" do
      base <> suffix
    else
      base <> suffix <> ext
    end
  end

  @doc """
  Determine the action needed for a trashed/removed file.

  ## Returns

    - `:archive` if the file existed locally (needs archiving)
    - `:ignore` if we have no local record (nothing to do)
  """
  @spec trash_action(SyncedFile.t() | nil) :: :archive | :ignore
  def trash_action(nil), do: :ignore
  def trash_action(%SyncedFile{}), do: :archive

  @doc """
  Generate an archive path for a locally-removed file.

  Appends `.archived.{timestamp}` before the extension.
  """
  @spec generate_archive_path(String.t()) :: String.t()
  def generate_archive_path(original_path) do
    timestamp = format_timestamp(DateTime.utc_now())
    ext = Path.extname(original_path)
    base = Path.rootname(original_path)
    suffix = ".archived.#{timestamp}"

    if ext == "" do
      base <> suffix
    else
      base <> suffix <> ext
    end
  end

  # -- Private --

  defp remote_is_newer?(remote_modified, nil), do: remote_modified != nil

  defp remote_is_newer?(remote_modified, local_synced_at) do
    DateTime.compare(remote_modified, local_synced_at) == :gt
  end

  # Local file is considered modified if checksums differ
  defp local_was_modified?(%SyncedFile{local_checksum: nil}), do: false
  defp local_was_modified?(%SyncedFile{remote_checksum: nil}), do: false

  defp local_was_modified?(%SyncedFile{local_checksum: local, remote_checksum: remote}) do
    local != remote
  end

  # Parse remote time — may be a DateTime, an ISO8601 string, or nil
  defp parse_remote_time(nil), do: nil
  defp parse_remote_time(%DateTime{} = dt), do: dt

  defp parse_remote_time(time_string) when is_binary(time_string) do
    case DateTime.from_iso8601(time_string) do
      {:ok, dt, _offset} -> dt
      {:error, _} -> nil
    end
  end

  defp parse_remote_time(_), do: nil

  defp format_timestamp(%DateTime{} = dt) do
    Calendar.strftime(dt, "%Y%m%dT%H%M%SZ")
  end
end
