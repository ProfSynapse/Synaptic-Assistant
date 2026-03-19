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

  alias Assistant.Billing.Policy
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
  Get a synced file by its workspace-local path.
  """
  @spec get_synced_file_by_local_path(binary(), String.t()) :: SyncedFile.t() | nil
  def get_synced_file_by_local_path(user_id, local_path) do
    SyncedFile
    |> where([f], f.user_id == ^user_id and f.local_path == ^local_path)
    |> Repo.one()
  end

  @doc """
  Create a new synced file record.
  """
  @spec create_synced_file(map()) :: {:ok, SyncedFile.t()} | {:error, Ecto.Changeset.t()}
  def create_synced_file(attrs) do
    with :ok <- maybe_allow_synced_file_insert(attrs) do
      %SyncedFile{}
      |> SyncedFile.changeset(attrs)
      |> Repo.insert()
    end
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
  Check whether an upstream write intent has already been applied for a user/file pair.

  Uses sync history details to detect prior successful processing of `intent_id`.
  """
  @spec write_intent_already_applied?(binary(), String.t(), String.t()) :: boolean()
  def write_intent_already_applied?(user_id, drive_file_id, intent_id)
      when is_binary(user_id) and is_binary(drive_file_id) and is_binary(intent_id) do
    case get_synced_file(user_id, drive_file_id) do
      nil ->
        false

      synced_file ->
        synced_file.id
        |> list_history(limit: 200)
        |> Enum.any?(&history_entry_matches_success_intent?(&1, intent_id))
    end
  end

  @doc """
  Record an upstream write-intent processing event in sync history.

  Returns `:ok` when the user/file mapping does not exist.
  """
  @spec record_upstream_intent_event(binary(), String.t(), String.t(), String.t(), map()) ::
          :ok | {:error, Ecto.Changeset.t()}
  def record_upstream_intent_event(user_id, drive_file_id, intent_id, event_type, details \\ %{})
      when is_binary(user_id) and is_binary(drive_file_id) and is_binary(intent_id) and
             is_binary(event_type) and is_map(details) do
    case get_synced_file(user_id, drive_file_id) do
      nil ->
        :ok

      synced_file ->
        operation = if event_type == "failure", do: "error", else: "upload"

        entry_details =
          details
          |> Map.put("source", "upstream_sync_worker")
          |> Map.put("intent_id", intent_id)
          |> Map.put("event_type", event_type)

        case create_history_entry(%{
               synced_file_id: synced_file.id,
               operation: operation,
               details: entry_details
             }) do
          {:ok, _entry} -> :ok
          {:error, changeset} -> {:error, changeset}
        end
    end
  end

  @doc """
  Record a write-coordinator event for a synced file identified by user and Drive file ID.

  Uses existing `sync_history.operation` values to avoid schema changes:

    * `upload` for attempt/retry/success write events
    * `conflict_detect` for conflict failures
    * `error` for non-conflict failures

  Returns `:ok` when no synced file exists for the provided identifiers.
  """
  @spec record_write_coordinator_event(binary(), String.t(), String.t(), map()) ::
          :ok | {:error, Ecto.Changeset.t()}
  def record_write_coordinator_event(user_id, drive_file_id, action, event)
      when is_binary(user_id) and is_binary(drive_file_id) and is_binary(action) and is_map(event) do
    case get_synced_file(user_id, drive_file_id) do
      nil ->
        :ok

      synced_file ->
        operation = coordinator_event_operation(event)

        details = %{
          "source" => "write_coordinator",
          "action" => action,
          "event_type" => to_string(Map.get(event, :type)),
          "measurements" => Map.get(event, :measurements, %{}),
          "metadata" => Map.get(event, :metadata, %{})
        }

        case create_history_entry(%{
               synced_file_id: synced_file.id,
               operation: operation,
               details: details
             }) do
          {:ok, _entry} -> :ok
          {:error, changeset} -> {:error, changeset}
        end
    end
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
    |> where([s], s.scope_type != "file")
    |> where_drive_id(drive_id)
    |> where_folder_id(folder_id)
    |> Repo.one()
  end

  @doc """
  Get a file scope by user, drive, and Drive file ID.
  """
  @spec get_file_scope(binary(), String.t() | nil, String.t()) :: SyncScope.t() | nil
  def get_file_scope(user_id, drive_id, file_id) do
    SyncScope
    |> where([s], s.user_id == ^user_id and s.scope_type == "file" and s.file_id == ^file_id)
    |> where_drive_id(drive_id)
    |> Repo.one()
  end

  @doc """
  Create or update a sync scope.
  """
  @spec upsert_scope(map()) :: {:ok, SyncScope.t()} | {:error, Ecto.Changeset.t()}
  def upsert_scope(attrs) do
    attrs = normalize_scope_attrs(attrs)

    %SyncScope{}
    |> SyncScope.changeset(attrs)
    |> Repo.insert(
      on_conflict:
        {:replace,
         [:folder_name, :file_name, :file_mime_type, :access_level, :scope_effect, :updated_at]},
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
    |> order_by([s], asc: s.scope_type, asc: s.folder_name, asc: s.file_name)
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
  Delete any explicit scopes matching the provided folder/file IDs within a drive.
  """
  @spec delete_scopes_in_targets(binary(), String.t() | nil, [String.t()], [String.t()]) ::
          {non_neg_integer(), nil}
  def delete_scopes_in_targets(user_id, drive_id, folder_ids, file_ids) do
    SyncScope
    |> where([s], s.user_id == ^user_id)
    |> where_drive_id(drive_id)
    |> where(
      [s],
      (s.scope_type == "folder" and s.folder_id in ^List.wrap(folder_ids)) or
        (s.scope_type == "file" and s.file_id in ^List.wrap(file_ids))
    )
    |> Repo.delete_all()
  end

  @doc """
  Check if a folder is within any of the user's sync scopes.

  Returns the matching scope if found, nil otherwise. Checks for both
  a folder-specific scope and an entire-drive scope (folder_id IS NULL).
  Used by the sync engine to determine if a changed file should be synced.
  """
  @spec folder_in_scope?(binary(), String.t() | nil, String.t()) :: SyncScope.t() | nil
  def folder_in_scope?(user_id, drive_id, folder_id) do
    case resolve_folder_scope(user_id, drive_id, folder_id) do
      %SyncScope{scope_effect: "include"} = scope -> scope
      _ -> nil
    end
  end

  @doc """
  Check whether a file is within any of the user's sync scopes.

  Prefers an exact file scope when present, otherwise falls back to
  folder/drive scopes.
  """
  @spec file_in_scope?(binary(), String.t() | nil, String.t() | nil, String.t()) ::
          SyncScope.t() | nil
  def file_in_scope?(user_id, drive_id, folder_id, file_id) do
    case resolve_file_scope(user_id, drive_id, folder_id, file_id) do
      %SyncScope{scope_effect: "include"} = scope -> scope
      _ -> nil
    end
  end

  # -------------------------------------------------------------------
  # Private Helpers
  # -------------------------------------------------------------------

  defp coordinator_event_operation(%{type: :failure, metadata: %{result_type: :conflict}}),
    do: "conflict_detect"

  defp coordinator_event_operation(%{type: :failure}), do: "error"
  defp coordinator_event_operation(_event), do: "upload"

  defp where_user_drive(query, user_id, nil) do
    where(query, [c], c.user_id == ^user_id and is_nil(c.drive_id))
  end

  defp where_user_drive(query, user_id, drive_id) do
    where(query, [c], c.user_id == ^user_id and c.drive_id == ^drive_id)
  end

  defp history_entry_matches_success_intent?(entry, intent_id) do
    details = entry.details || %{}

    details["intent_id"] == intent_id and
      details["event_type"] == "success" and
      details["source"] in ["upstream_sync_worker", "write_coordinator"]
  end

  defp resolve_file_scope(user_id, drive_id, folder_id, file_id) do
    case get_file_scope(user_id, drive_id, file_id) do
      nil -> resolve_folder_scope(user_id, drive_id, folder_id)
      scope -> scope
    end
  end

  defp resolve_folder_scope(user_id, drive_id, folder_id) do
    query =
      SyncScope
      |> where([s], s.user_id == ^user_id)
      |> where([s], s.scope_type in ["drive", "folder"])
      |> where_drive_id(drive_id)

    query =
      case folder_id do
        nil ->
          where(query, [s], is_nil(s.folder_id))

        value ->
          where(query, [s], s.folder_id == ^value or is_nil(s.folder_id))
      end

    query =
      query
      |> order_by([s], desc_nulls_last: s.folder_id)
      |> limit(1)

    Repo.one(query)
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

  defp normalize_scope_attrs(attrs) do
    case Map.get(attrs, :scope_type) || Map.get(attrs, "scope_type") do
      nil ->
        inferred =
          cond do
            present_scope_value?(Map.get(attrs, :file_id) || Map.get(attrs, "file_id")) -> "file"
            is_nil(Map.get(attrs, :folder_id) || Map.get(attrs, "folder_id")) -> "drive"
            true -> "folder"
          end

        Map.put(attrs, :scope_type, inferred)

      _ ->
        attrs
    end
  end

  # Partial unique indexes require unsafe_fragment for conflict_target
  defp conflict_target_for_cursor(%{drive_id: nil}),
    do: {:unsafe_fragment, ~s|(user_id) WHERE drive_id IS NULL|}

  defp conflict_target_for_cursor(%{drive_id: _}),
    do: {:unsafe_fragment, ~s|(user_id, drive_id) WHERE drive_id IS NOT NULL|}

  defp conflict_target_for_cursor(_),
    do: {:unsafe_fragment, ~s|(user_id) WHERE drive_id IS NULL|}

  defp conflict_target_for_scope(%{scope_type: "file", drive_id: nil}),
    do:
      {:unsafe_fragment,
       ~s|(user_id, file_id) WHERE drive_id IS NULL AND scope_type = 'file' AND file_id IS NOT NULL|}

  defp conflict_target_for_scope(%{scope_type: "file", drive_id: _}),
    do:
      {:unsafe_fragment,
       ~s|(user_id, drive_id, file_id) WHERE drive_id IS NOT NULL AND scope_type = 'file' AND file_id IS NOT NULL|}

  # 4-way partial indexes for non-file scope: drive_id x folder_id nullability
  defp conflict_target_for_scope(%{drive_id: nil, folder_id: nil}),
    do:
      {:unsafe_fragment,
       ~s|(user_id) WHERE drive_id IS NULL AND folder_id IS NULL AND scope_type != 'file'|}

  defp conflict_target_for_scope(%{drive_id: nil, folder_id: _}),
    do:
      {:unsafe_fragment,
       ~s|(user_id, folder_id) WHERE drive_id IS NULL AND folder_id IS NOT NULL AND scope_type != 'file'|}

  defp conflict_target_for_scope(%{drive_id: _, folder_id: nil}),
    do:
      {:unsafe_fragment,
       ~s|(user_id, drive_id) WHERE drive_id IS NOT NULL AND folder_id IS NULL AND scope_type != 'file'|}

  defp conflict_target_for_scope(%{drive_id: _, folder_id: _}),
    do:
      {:unsafe_fragment,
       ~s|(user_id, drive_id, folder_id) WHERE drive_id IS NOT NULL AND folder_id IS NOT NULL AND scope_type != 'file'|}

  # Default: personal drive, entire drive
  defp conflict_target_for_scope(_),
    do:
      {:unsafe_fragment,
       ~s|(user_id) WHERE drive_id IS NULL AND folder_id IS NULL AND scope_type != 'file'|}

  defp present_scope_value?(value) when is_binary(value), do: String.trim(value) != ""
  defp present_scope_value?(value), do: not is_nil(value)

  defp maybe_allow_synced_file_insert(attrs) do
    user_id = Map.get(attrs, :user_id) || Map.get(attrs, "user_id")
    content = Map.get(attrs, :content) || Map.get(attrs, "content")

    Policy.ensure_retained_write_allowed(user_id, Policy.synced_file_growth(nil, content))
  end
end
