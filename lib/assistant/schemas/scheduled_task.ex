defmodule Assistant.Schemas.ScheduledTask do
  @moduledoc """
  Scheduled task schema. Defines recurring skill executions on a
  cron schedule. Quantum triggers Oban jobs at the scheduled times.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "scheduled_tasks" do
    field :skill_id, :string
    field :parameters, :map, default: %{}
    field :cron_expression, :string
    field :channel, :string
    field :timezone, :string, default: "UTC"
    field :enabled, :boolean, default: true
    field :last_run_at, :utc_datetime_usec
    field :next_run_at, :utc_datetime_usec

    belongs_to :user, Assistant.Schemas.User

    timestamps(type: :utc_datetime_usec)
  end

  @required_fields [:skill_id, :cron_expression, :channel, :user_id]
  @optional_fields [:parameters, :timezone, :enabled, :last_run_at, :next_run_at]

  def changeset(scheduled_task, attrs) do
    scheduled_task
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> foreign_key_constraint(:user_id)
  end
end
