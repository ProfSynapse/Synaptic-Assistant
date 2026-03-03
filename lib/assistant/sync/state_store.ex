# lib/assistant/sync/state_store.ex — Ecto context for sync engine state.
#
# Provides CRUD operations for all sync-related schemas: cursors, synced
# files, history entries, and scopes. The sync workers and coordinator
# use this module to persist sync state between poll cycles.
#
# Related files:
#   - lib/assistant/schemas/sync_cursor.ex
#   - lib/assistant/schemas/synced_file.ex
#   - lib/assistant/schemas/sync_history_entry.ex
#   - lib/assistant/schemas/sync_scope.ex

defmodule Assistant.Sync.StateStore do
  @moduledoc """
  Ecto context for the sync engine's persistent state.

  All sync state operations go through this module. It handles cursors
  (for tracking the Changes API token), synced files (the file mapping),
  sync history (audit log), and sync scopes (permissions).
  """

  import Ecto.Query

  alias Assistant.Repo
  alias Assistant.Schemas.{SyncCursor, SyncedFile, SyncHistoryEntry, SyncScope}

  # -------------------------------------------------------------------
  # Cursors
  # -------------------------------------------------------------------

  @doc """
  Get the sync cursor for a user's drive.

  Pass `nil` as `drive_id` for the personal drive.
  """
  @spec get_cursor(binary(), String.t() | nil) :: SyncCursor.t() | nil
  def get_cursor(user_id, drive_id) do
    SyncCursor
    |> where_user_drive(user_id, drive_id)
    |> Repo.one()
  end

  @doc """
  Create or update the sync cursor for a user's drive.

  Uses upsert semantics: if a cursor already exists for the user+drive
  combination, the `start_page_token` and `last_poll_at` are updated.
  """
  @spec upsert_cursor(map()) :: {:ok, SyncCursor.t()} | {:error, Ecto.Changeset.t()}
  def upsert_cursor(attrs) do
    %SyncCursor{}
    |> SyncCursor.changeset(attrs)
    |> Repo.insert(
      on_conflict: {:replace, [:start_page_token, :last_poll_at, :updated_at]},
      conflict_target: conflict_target_for_cursor(attrs),
      returning: true
    )
  end

  @doc """
  List all cursors for a user (one per connected drive).
  """
  @spec list_cursors(binary()) :: [SyncCursor.t()]
  def list_cursors(user_id) do
    SyncCursor
    |> where([c], c.user_id == ^user_id)
    |> Repo.all()
  end

  @doc """
  Delete the cursor for a user's drive.
  """
  @spec delete_cursor(binary(), String.t() | nil) :: {non_neg_integer(), nil}
  def delete_cursor(user_id, drive_id) do
    SyncCursor
    |> where_user_drive(user_id, drive_id)
    |> Repo.delete_all()
  end

  # -------------------------------------------------------------------
  # Synced Files
  # -------------------------------------------------------------------

  @doc """
  Get a synced file by user ID and Drive file ID.
  """
  @spec get_synced_file(binary(), String.t()) :: SyncedFile.t() | nil
  def get_synced_file(user_id, drive_file_id) do
    SyncedFile
    |> where([f], f.user_id == ^user_id and f.drive_file_id == ^drive_file_id)
    |> Repo.one()
  end

  @doc """
  Get a synced file by its primary key ID.
  """
  @spec get_synced_file_by_id(binary()) :: SyncedFile.t() | nil
  def get_synced_file_by_id(id) do
    Repo.get(SyncedFile, id)
  end

  @doc """
  Create a new synced file record.
  """
  @spec create_synced_file(map()) :: {:ok, SyncedFile.t()} | {:error, Ecto.Changeset.t()}
  def create_synced_file(attrs) do
    %SyncedFile{}
    |> SyncedFile.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Update sync state fields on an existing synced file.
  """
  @spec update_synced_file(SyncedFile.t(), map()) ::
          {:ok, SyncedFile.t()} | {:error, Ecto.Changeset.t()}
  def update_synced_file(%SyncedFile{} = synced_file, attrs) do
    synced_file
    |> SyncedFile.sync_changeset(attrs)
    |> Repo.update()
  end

  @doc """
  List all synced files for a user, optionally filtered by status.
  """
  @spec list_synced_files(binary(), keyword()) :: [SyncedFile.t()]
  def list_synced_files(user_id, opts \\ []) do
    query =
      SyncedFile
      |> where([f], f.user_id == ^user_id)

    query =
      case Keyword.get(opts, :status) do
        nil -> query
        status -> where(query, [f], f.sync_status == ^status)
      end

    query =
      case Keyword.get(opts, :drive_id) do
        nil -> query
        :personal -> where(query, [f], is_nil(f.drive_id))
        drive_id -> where(query, [f], f.drive_id == ^drive_id)
      end

    query
    |> order_by([f], desc: f.updated_at)
    |> Repo.all()
  end

  @doc """
  Count synced files for a user, grouped by status.

  Returns a map like `%{"synced" => 10, "conflict" => 2, "error" => 1}`.
  """
  @spec count_synced_files_by_status(binary()) :: map()
  def count_synced_files_by_status(user_id) do
    SyncedFile
    |> where([f], f.user_id == ^user_id)
    |> group_by([f], f.sync_status)
    |> select([f], {f.sync_status, count(f.id)})
    |> Repo.all()
    |> Map.new()
  end

  @doc """
  Delete a synced file record and its history (cascading).
  """
  @spec delete_synced_file(SyncedFile.t()) :: {:ok, SyncedFile.t()} | {:error, Ecto.Changeset.t()}
  def delete_synced_file(%SyncedFile{} = synced_file) do
    Repo.delete(synced_file)
  end

  # -------------------------------------------------------------------
  # Sync History
  # -------------------------------------------------------------------

  @doc """
  Record a sync history entry for a synced file.
  """
  @spec create_history_entry(map()) ::
          {:ok, SyncHistoryEntry.t()} | {:error, Ecto.Changeset.t()}
  def create_history_entry(attrs) do
    %SyncHistoryEntry{}
    |> SyncHistoryEntry.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  List sync history entries for a synced file, most recent first.
  """
  @spec list_history(binary(), keyword()) :: [SyncHistoryEntry.t()]
  def list_history(synced_file_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)

    SyncHistoryEntry
    |> where([h], h.synced_file_id == ^synced_file_id)
    |> order_by([h], desc: h.inserted_at)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc """
  List recent sync history for a user across all files.

  Joins with synced_files to filter by user_id.
  """
  @spec list_user_history(binary(), keyword()) :: [map()]
  def list_user_history(user_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)

    SyncHistoryEntry
    |> join(:inner, [h], f in SyncedFile, on: h.synced_file_id == f.id)
    |> where([h, f], f.user_id == ^user_id)
    |> order_by([h, f], desc: h.inserted_at)
    |> limit(^limit)
    |> select([h, f], %{
      id: h.id,
      operation: h.operation,
      details: h.details,
      inserted_at: h.inserted_at,
      file_name: f.drive_file_name,
      drive_file_id: f.drive_file_id
    })
    |> Repo.all()
  end

  # -------------------------------------------------------------------
  # Sync Scopes
  # -------------------------------------------------------------------

  @doc """
  Get a sync scope by user, drive, and folder.

  Pass `nil` as `drive_id` for personal drive folders.
  Pass `nil` as `folder_id` for entire-drive scopes.
  """
  @spec get_scope(binary(), String.t() | nil, String.t() | nil) :: SyncScope.t() | nil
  def get_scope(user_id, drive_id, folder_id) do
    SyncScope
    |> where([s], s.user_id == ^user_id)
    |> where_drive_id(drive_id)
    |> where_folder_id(folder_id)
    |> Repo.one()
  end

  @doc """
  Create or update a sync scope.
  """
  @spec upsert_scope(map()) :: {:ok, SyncScope.t()} | {:error, Ecto.Changeset.t()}
  def upsert_scope(attrs) do
    %SyncScope{}
    |> SyncScope.changeset(attrs)
    |> Repo.insert(
      on_conflict: {:replace, [:folder_name, :access_level, :updated_at]},
      conflict_target: conflict_target_for_scope(attrs),
      returning: true
    )
  end

  @doc """
  List all sync scopes for a user, optionally filtered by drive.
  """
  @spec list_scopes(binary(), keyword()) :: [SyncScope.t()]
  def list_scopes(user_id, opts \\ []) do
    query =
      SyncScope
      |> where([s], s.user_id == ^user_id)

    query =
      case Keyword.get(opts, :drive_id) do
        nil -> query
        :personal -> where(query, [s], is_nil(s.drive_id))
        drive_id -> where(query, [s], s.drive_id == ^drive_id)
      end

    query
    |> order_by([s], asc: s.folder_name)
    |> Repo.all()
  end

  @doc """
  Delete a sync scope.
  """
  @spec delete_scope(SyncScope.t()) :: {:ok, SyncScope.t()} | {:error, Ecto.Changeset.t()}
  def delete_scope(%SyncScope{} = scope) do
    Repo.delete(scope)
  end

  @doc """
  Check if a folder is within any of the user's sync scopes.

  Returns the matching scope if found, nil otherwise. Checks for both
  a folder-specific scope and an entire-drive scope (folder_id IS NULL).
  Used by the sync engine to determine if a changed file should be synced.
  """
  @spec folder_in_scope?(binary(), String.t() | nil, String.t()) :: SyncScope.t() | nil
  def folder_in_scope?(user_id, drive_id, folder_id) do
    # Single query: match either folder-specific scope or entire-drive scope.
    # Order by folder_id DESC NULLS LAST so folder-specific matches are preferred.
    query =
      SyncScope
      |> where([s], s.user_id == ^user_id)
      |> where_drive_id(drive_id)
      |> where([s], s.folder_id == ^folder_id or is_nil(s.folder_id))
      |> order_by([s], desc_nulls_last: s.folder_id)
      |> limit(1)

    Repo.one(query)
  end

  # -------------------------------------------------------------------
  # Private Helpers
  # -------------------------------------------------------------------

  defp where_user_drive(query, user_id, nil) do
    where(query, [c], c.user_id == ^user_id and is_nil(c.drive_id))
  end

  defp where_user_drive(query, user_id, drive_id) do
    where(query, [c], c.user_id == ^user_id and c.drive_id == ^drive_id)
  end

  defp where_drive_id(query, nil) do
    where(query, [s], is_nil(s.drive_id))
  end

  defp where_drive_id(query, drive_id) do
    where(query, [s], s.drive_id == ^drive_id)
  end

  defp where_folder_id(query, nil) do
    where(query, [s], is_nil(s.folder_id))
  end

  defp where_folder_id(query, folder_id) do
    where(query, [s], s.folder_id == ^folder_id)
  end

  # Partial unique indexes require unsafe_fragment for conflict_target
  defp conflict_target_for_cursor(%{drive_id: nil}),
    do: {:unsafe_fragment, ~s|(user_id) WHERE drive_id IS NULL|}

  defp conflict_target_for_cursor(%{drive_id: _}),
    do: {:unsafe_fragment, ~s|(user_id, drive_id) WHERE drive_id IS NOT NULL|}

  defp conflict_target_for_cursor(_),
    do: {:unsafe_fragment, ~s|(user_id) WHERE drive_id IS NULL|}

  # 4-way partial indexes for scope: drive_id x folder_id nullability
  defp conflict_target_for_scope(%{drive_id: nil, folder_id: nil}),
    do: {:unsafe_fragment, ~s|(user_id) WHERE drive_id IS NULL AND folder_id IS NULL|}

  defp conflict_target_for_scope(%{drive_id: nil, folder_id: _}),
    do:
      {:unsafe_fragment,
       ~s|(user_id, folder_id) WHERE drive_id IS NULL AND folder_id IS NOT NULL|}

  defp conflict_target_for_scope(%{drive_id: _, folder_id: nil}),
    do:
      {:unsafe_fragment, ~s|(user_id, drive_id) WHERE drive_id IS NOT NULL AND folder_id IS NULL|}

  defp conflict_target_for_scope(%{drive_id: _, folder_id: _}),
    do:
      {:unsafe_fragment,
       ~s|(user_id, drive_id, folder_id) WHERE drive_id IS NOT NULL AND folder_id IS NOT NULL|}

  # Default: personal drive, entire drive
  defp conflict_target_for_scope(_),
    do: {:unsafe_fragment, ~s|(user_id) WHERE drive_id IS NULL AND folder_id IS NULL|}
end
