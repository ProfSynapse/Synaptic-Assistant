defmodule Assistant.Schemas.FileOperationLog do
  @moduledoc """
  File operation log schema. Step-level audit trail for the
  non-destructive versioning workflow (pull/manipulate/archive/verify/replace/record).
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @steps ~w(pull manipulate archive verify replace record)
  @step_statuses ~w(started completed failed)

  schema "file_operation_logs" do
    field :step, :string
    field :status, :string
    field :details, :map, default: %{}

    belongs_to :file_version, Assistant.Schemas.FileVersion

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @required_fields [:step, :status, :file_version_id]
  @optional_fields [:details]

  def changeset(log, attrs) do
    log
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:step, @steps)
    |> validate_inclusion(:status, @step_statuses)
    |> foreign_key_constraint(:file_version_id)
  end
end
