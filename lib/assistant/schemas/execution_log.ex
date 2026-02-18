defmodule Assistant.Schemas.ExecutionLog do
  @moduledoc """
  Execution log schema. Tracks skill executions including parameters,
  results, timing, and sub-agent trace via parent_execution_id.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses ~w(pending running completed failed timeout)

  schema "execution_logs" do
    field :skill_id, :string
    field :parameters, :map, default: %{}
    field :result, :map
    field :status, :string, default: "pending"
    field :error_message, :string
    field :duration_ms, :integer
    field :started_at, :utc_datetime_usec
    field :completed_at, :utc_datetime_usec

    # Sub-agent trace: links child execution to parent
    field :parent_execution_id, :binary_id

    belongs_to :conversation, Assistant.Schemas.Conversation

    timestamps(type: :utc_datetime_usec)
  end

  @required_fields [:skill_id, :conversation_id]
  @optional_fields [
    :parameters,
    :result,
    :status,
    :error_message,
    :duration_ms,
    :started_at,
    :completed_at,
    :parent_execution_id
  ]

  def changeset(log, attrs) do
    log
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:status, @statuses)
    |> foreign_key_constraint(:conversation_id)
  end
end
