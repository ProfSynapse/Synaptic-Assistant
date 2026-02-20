defmodule Assistant.Schemas.ConnectedDrive do
  @moduledoc """
  Represents a Google Drive (personal or shared) connected to a user's account.

  Each row maps a user to a specific drive they have authorized the agent to access.
  The `enabled` flag controls whether the drive is actively used for file operations.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @derive {Jason.Encoder, only: [:id, :drive_id, :drive_name, :drive_type, :enabled]}

  @drive_types ~w(personal shared)

  schema "connected_drives" do
    field :drive_id, :string
    field :drive_name, :string
    field :drive_type, :string
    field :enabled, :boolean, default: true

    belongs_to :user, Assistant.Schemas.User

    timestamps(type: :utc_datetime_usec)
  end

  @required_fields [:user_id, :drive_name, :drive_type]
  @optional_fields [:drive_id, :enabled]

  def changeset(drive, attrs) do
    drive
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:drive_type, @drive_types)
    |> validate_personal_drive_id()
    |> unique_constraint([:user_id, :drive_id],
      name: :connected_drives_user_drive_unique,
      message: "this shared drive is already connected"
    )
    |> unique_constraint([:user_id],
      name: :connected_drives_user_personal_unique,
      message: "personal drive already connected"
    )
  end

  defp validate_personal_drive_id(changeset) do
    drive_type = get_field(changeset, :drive_type)
    drive_id = get_field(changeset, :drive_id)

    cond do
      drive_type == "personal" and not is_nil(drive_id) ->
        add_error(changeset, :drive_id, "must be nil for personal drives")

      drive_type == "shared" and is_nil(drive_id) ->
        add_error(changeset, :drive_id, "is required for shared drives")

      true ->
        changeset
    end
  end
end
