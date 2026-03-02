# lib/assistant/schemas/sync_history_entry.ex — Append-only audit log for sync operations.
#
# Records every sync operation for a given synced file. Append-only by
# design: rows are only inserted, never updated. The `details` map stores
# operation-specific metadata (e.g., checksums, error messages, conflict
# resolution outcome).
#
# Related files:
#   - lib/assistant/schemas/synced_file.ex (parent record)
#   - lib/assistant/sync/state_store.ex (CRUD context)
#   - priv/repo/migrations/20260302140002_create_sync_history.exs (migration)

defmodule Assistant.Schemas.SyncHistoryEntry do
  @moduledoc """
  Append-only audit log entry for a sync operation.

  Each entry records a single sync event for a tracked file. The `operation`
  field indicates what happened, and `details` provides context.

  ## Operation Values

  - `download` — file downloaded from Drive to local
  - `upload` — file uploaded from local to Drive
  - `conflict_detect` — conflict detected between local and remote
  - `conflict_resolve` — conflict resolved (details map has resolution strategy)
  - `delete_local` — local file removed from sync tracking
  - `trash` — remote file moved to trash
  - `untrash` — remote file restored from trash
  - `error` — sync operation failed
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @operations ~w(download upload conflict_detect conflict_resolve delete_local trash untrash error)

  schema "sync_history" do
    field :operation, :string
    field :details, :map, default: %{}
    field :inserted_at, :utc_datetime_usec, read_after_writes: true

    belongs_to :synced_file, Assistant.Schemas.SyncedFile
  end

  @required_fields [:synced_file_id, :operation]
  @optional_fields [:details]

  def changeset(entry, attrs) do
    entry
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:operation, @operations)
    |> check_constraint(:operation, name: :valid_operation)
  end
end
