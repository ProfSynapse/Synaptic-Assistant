defmodule Assistant.Schemas.TaskDependency do
  @moduledoc """
  Task dependency schema. Represents a blocking relationship between
  two tasks: blocking_task must complete before blocked_task can proceed.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "task_dependencies" do
    belongs_to :blocking_task, Assistant.Schemas.Task
    belongs_to :blocked_task, Assistant.Schemas.Task

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @required_fields [:blocking_task_id, :blocked_task_id]

  def changeset(dependency, attrs) do
    dependency
    |> cast(attrs, @required_fields)
    |> validate_required(@required_fields)
    |> unique_constraint([:blocking_task_id, :blocked_task_id])
    |> check_constraint(:blocking_task_id, name: :no_self_dependency)
    |> foreign_key_constraint(:blocking_task_id)
    |> foreign_key_constraint(:blocked_task_id)
  end
end
