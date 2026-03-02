# lib/assistant/schemas/sync_scope.ex — Granular per-folder sync permissions.
#
# Controls which Drive folders the sync engine is allowed to access and at
# what permission level. Users select specific folders from their connected
# drives and assign read-only or read-write access. The sync engine consults
# these scopes before downloading or uploading files.
#
# When `folder_id` is nil, the scope covers the entire drive. This follows
# the same nullable-field partial-index pattern as `connected_drives.drive_id`.
#
# Related files:
#   - lib/assistant/schemas/connected_drive.ex (parent drive connection)
#   - lib/assistant/sync/state_store.ex (CRUD context)
#   - priv/repo/migrations/20260302140003_create_sync_scopes.exs (migration)

defmodule Assistant.Schemas.SyncScope do
  @moduledoc """
  Granular per-folder sync permission for the sync engine.

  Each scope grants the sync engine access to a specific folder (or an entire
  drive when `folder_id` is nil) with either read-only or read-write permissions.
  The `drive_id` is nil for personal (My Drive) and set to the shared drive ID
  for shared drives.

  ## Access Levels

  - `read_only` — agent can read, download, and search files in this folder
  - `read_write` — agent can also write, update, and archive files
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @access_levels ~w(read_only read_write)

  schema "sync_scopes" do
    field :drive_id, :string
    field :folder_id, :string
    field :folder_name, :string
    field :access_level, :string, default: "read_only"

    belongs_to :user, Assistant.Schemas.User

    timestamps(type: :utc_datetime_usec)
  end

  @required_fields [:user_id, :folder_name]
  @optional_fields [:drive_id, :folder_id, :access_level]

  def changeset(scope, attrs) do
    scope
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:access_level, @access_levels)
    # Shared drive + specific folder
    |> unique_constraint([:user_id, :drive_id, :folder_id],
      name: :sync_scopes_user_drive_folder_unique,
      message: "scope already exists for this folder"
    )
    # Shared drive + entire drive
    |> unique_constraint([:user_id, :drive_id],
      name: :sync_scopes_user_drive_all_unique,
      message: "scope already exists for this entire drive"
    )
    # Personal drive + specific folder
    |> unique_constraint([:user_id, :folder_id],
      name: :sync_scopes_user_personal_folder_unique,
      message: "scope already exists for this personal drive folder"
    )
    # Personal drive + entire drive
    |> unique_constraint([:user_id],
      name: :sync_scopes_user_personal_all_unique,
      message: "scope already exists for entire personal drive"
    )
    |> check_constraint(:access_level, name: :valid_access_level)
  end
end
