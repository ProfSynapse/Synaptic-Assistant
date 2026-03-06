# lib/assistant/schemas/sync_scope.ex — Granular Drive sync permissions.
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
  Granular Drive sync permission for the sync engine.

  Each scope grants the sync engine access to a specific drive, folder, or file.
  Legacy drive/folder scopes continue using `folder_id`/`folder_name`; file scopes
  additionally populate `file_id`/`file_name`/`file_mime_type`.

  ## Access Levels

  - `read_only` — agent can read, download, and search files in this folder
  - `read_write` — agent can also write, update, and archive files
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @access_levels ~w(read_only read_write)
  @scope_types ~w(drive folder file)
  @scope_effects ~w(include exclude)

  schema "sync_scopes" do
    field :scope_type, :string, default: "folder"
    field :scope_effect, :string, default: "include"
    field :drive_id, :string
    field :folder_id, :string
    field :folder_name, :string
    field :file_id, :string
    field :file_name, :string
    field :file_mime_type, :string
    field :access_level, :string, default: "read_only"

    belongs_to :user, Assistant.Schemas.User

    timestamps(type: :utc_datetime_usec)
  end

  @required_fields [:user_id, :folder_name]
  @optional_fields [
    :drive_id,
    :folder_id,
    :file_id,
    :file_name,
    :file_mime_type,
    :access_level,
    :scope_effect
  ]

  def changeset(scope, attrs) do
    scope
    |> cast(attrs, @required_fields ++ @optional_fields ++ [:scope_type])
    |> put_default_scope_type()
    |> validate_required(@required_fields)
    |> validate_inclusion(:access_level, @access_levels)
    |> validate_inclusion(:scope_type, @scope_types)
    |> validate_inclusion(:scope_effect, @scope_effects)
    |> validate_scope_fields()
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
    |> unique_constraint([:user_id, :drive_id, :file_id],
      name: :sync_scopes_user_drive_file_unique,
      message: "scope already exists for this file"
    )
    |> unique_constraint([:user_id, :file_id],
      name: :sync_scopes_user_personal_file_unique,
      message: "scope already exists for this file"
    )
    |> check_constraint(:access_level, name: :valid_access_level)
    |> check_constraint(:scope_type, name: :valid_scope_type)
    |> check_constraint(:scope_effect, name: :valid_scope_effect)
  end

  defp validate_scope_fields(changeset) do
    scope_type = get_field(changeset, :scope_type)
    file_name = get_field(changeset, :file_name)
    folder_name = get_field(changeset, :folder_name)

    case scope_type do
      "drive" ->
        changeset
        |> ensure_absent(:file_id, "must be blank for drive scopes")
        |> ensure_absent(:file_name, "must be blank for drive scopes")

      "folder" ->
        changeset
        |> validate_required([:folder_id])
        |> ensure_absent(:file_id, "must be blank for folder scopes")
        |> ensure_absent(:file_name, "must be blank for folder scopes")

      "file" ->
        changeset
        |> validate_required([:file_id, :file_name])
        |> validate_required_name(folder_name, file_name)

      _ ->
        changeset
    end
  end

  defp put_default_scope_type(changeset) do
    case get_change(changeset, :scope_type) do
      nil ->
        inferred =
          cond do
            present?(get_field(changeset, :file_id)) -> "file"
            is_nil(get_field(changeset, :folder_id)) -> "drive"
            true -> "folder"
          end

        put_change(changeset, :scope_type, inferred)

      _ ->
        changeset
    end
  end

  defp validate_required_name(changeset, folder_name, file_name) do
    if is_binary(folder_name) and String.trim(folder_name) != "" do
      changeset
    else
      put_change(changeset, :folder_name, file_name)
    end
  end

  defp ensure_absent(changeset, field, message) do
    case get_field(changeset, field) do
      nil -> changeset
      "" -> changeset
      _ -> add_error(changeset, field, message)
    end
  end

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(value), do: not is_nil(value)
end
