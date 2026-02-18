defmodule Assistant.Schemas.FileVersion do
  @moduledoc """
  File version schema. Tracks every file operation in the non-destructive
  versioning workflow (SYNC/NORMALIZE/ARCHIVE/PUBLISH).
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @operations ~w(create update archive restore)
  @sync_statuses ~w(synced pending_sync sync_failed)

  schema "file_versions" do
    field :drive_file_id, :string
    field :drive_file_name, :string
    field :drive_folder_id, :string
    field :canonical_type, :string
    field :normalized_format, :string
    field :version_number, :integer, default: 1
    field :archive_file_id, :string
    field :archive_folder_id, :string
    field :checksum_before, :string
    field :checksum_after, :string
    field :operation, :string
    field :sync_status, :string, default: "synced"

    belongs_to :skill_execution, Assistant.Schemas.ExecutionLog

    timestamps(type: :utc_datetime_usec)
  end

  @required_fields [
    :drive_file_id,
    :drive_file_name,
    :canonical_type,
    :normalized_format,
    :operation
  ]
  @optional_fields [
    :drive_folder_id,
    :version_number,
    :archive_file_id,
    :archive_folder_id,
    :checksum_before,
    :checksum_after,
    :sync_status,
    :skill_execution_id
  ]

  def changeset(file_version, attrs) do
    file_version
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:operation, @operations)
    |> validate_inclusion(:sync_status, @sync_statuses)
    |> validate_number(:version_number, greater_than: 0)
    |> foreign_key_constraint(:skill_execution_id)
  end
end
