# lib/assistant/schemas/synced_file.ex — Maps a Google Drive file to its local synced copy.
#
# Tracks the bidirectional mapping between a file in Google Drive and its
# local representation (Markdown, CSV, etc.). Stores checksums and timestamps
# on both sides for conflict detection. The `sync_status` field drives the
# sync engine's decision logic.
#
# Related files:
#   - lib/assistant/schemas/sync_history_entry.ex (audit log per file)
#   - lib/assistant/sync/state_store.ex (CRUD context)
#   - priv/repo/migrations/20260302140001_create_synced_files.exs (migration)

defmodule Assistant.Schemas.SyncedFile do
  @moduledoc """
  Maps a Google Drive file to its local synced copy.

  Each record represents a single file being tracked by the sync engine.
  The sync engine compares `remote_modified_at` / `remote_checksum` against
  `local_modified_at` / `local_checksum` to determine sync direction and
  detect conflicts.

  ## Sync Status Values

  - `synced` — local and remote are in agreement
  - `local_ahead` — local file has been modified since last sync
  - `remote_ahead` — remote file has been modified since last sync
  - `conflict` — both sides modified since last sync
  - `error` — last sync attempt failed (see `sync_error`)
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @sync_statuses ~w(synced local_ahead remote_ahead conflict error)
  @local_formats ~w(md csv txt json bin)

  schema "synced_files" do
    field :drive_file_id, :string
    field :drive_file_name, :string
    field :drive_mime_type, :string
    field :local_path, :string
    field :local_format, :string
    field :remote_modified_at, :utc_datetime_usec
    field :local_modified_at, :utc_datetime_usec
    field :remote_checksum, :string
    field :local_checksum, :string
    field :sync_status, :string, default: "synced"
    field :last_synced_at, :utc_datetime_usec
    field :sync_error, :string
    field :drive_id, :string
    field :file_size, :integer

    belongs_to :user, Assistant.Schemas.User
    has_many :sync_history, Assistant.Schemas.SyncHistoryEntry

    timestamps(type: :utc_datetime_usec)
  end

  @required_fields [
    :user_id,
    :drive_file_id,
    :drive_file_name,
    :drive_mime_type,
    :local_path,
    :local_format
  ]

  @optional_fields [
    :remote_modified_at,
    :local_modified_at,
    :remote_checksum,
    :local_checksum,
    :sync_status,
    :last_synced_at,
    :sync_error,
    :drive_id,
    :file_size
  ]

  def changeset(synced_file, attrs) do
    synced_file
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:sync_status, @sync_statuses)
    |> validate_inclusion(:local_format, @local_formats)
    |> unique_constraint([:user_id, :drive_file_id])
    |> check_constraint(:sync_status, name: :valid_sync_status)
    |> check_constraint(:local_format, name: :valid_local_format)
  end

  @doc """
  Changeset for updating sync state after a successful sync operation.
  Only allows sync-related fields to be changed.
  """
  def sync_changeset(synced_file, attrs) do
    synced_file
    |> cast(attrs, [
      :remote_modified_at,
      :local_modified_at,
      :remote_checksum,
      :local_checksum,
      :sync_status,
      :last_synced_at,
      :sync_error,
      :drive_file_name,
      :file_size
    ])
    |> validate_inclusion(:sync_status, @sync_statuses)
    |> check_constraint(:sync_status, name: :valid_sync_status)
  end
end
