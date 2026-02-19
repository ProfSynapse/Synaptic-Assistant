defmodule Assistant.Schemas.TaskHistory do
  @moduledoc """
  Task history schema. Audit trail of all field changes on a task.
  Every mutation is logged for "what changed on this task?" queries.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "task_history" do
    field :field_changed, :string
    field :old_value, :string
    field :new_value, :string

    belongs_to :task, Assistant.Schemas.Task
    belongs_to :changed_by_user, Assistant.Schemas.User
    belongs_to :changed_via_conversation, Assistant.Schemas.Conversation

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @required_fields [:field_changed, :task_id]
  @optional_fields [:old_value, :new_value, :changed_by_user_id, :changed_via_conversation_id]

  def changeset(history, attrs) do
    history
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> foreign_key_constraint(:task_id)
    |> foreign_key_constraint(:changed_by_user_id)
    |> foreign_key_constraint(:changed_via_conversation_id)
  end
end
