defmodule Assistant.Schemas.Task do
  @moduledoc """
  Task schema. First-class task management with short_id references,
  subtask hierarchy, recurrence support, tags, full-text search,
  and soft delete via archived_at.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses ~w(todo in_progress blocked done cancelled)
  @priorities ~w(critical high medium low)
  @archive_reasons ~w(completed cancelled superseded)

  schema "tasks" do
    field :short_id, :string
    field :title, :string
    field :description, :string
    field :status, :string, default: "todo"
    field :priority, :string, default: "medium"
    field :tags, {:array, :string}, default: []
    field :due_date, :date
    field :due_time, :utc_datetime_usec
    field :started_at, :utc_datetime_usec
    field :completed_at, :utc_datetime_usec
    field :archived_at, :utc_datetime_usec
    field :archive_reason, :string
    field :recurrence_rule, :map
    field :metadata, :map, default: %{}

    # search_vector is a generated tsvector column (read-only in Elixir)

    belongs_to :assignee, Assistant.Schemas.User
    belongs_to :creator, Assistant.Schemas.User
    belongs_to :created_via_conversation, Assistant.Schemas.Conversation
    belongs_to :parent_task, Assistant.Schemas.Task
    belongs_to :recurrence_source, Assistant.Schemas.Task

    has_many :subtasks, Assistant.Schemas.Task, foreign_key: :parent_task_id
    has_many :comments, Assistant.Schemas.TaskComment
    has_many :history, Assistant.Schemas.TaskHistory

    timestamps(type: :utc_datetime_usec)
  end

  @required_fields [:title]
  @optional_fields [
    :short_id,
    :description,
    :status,
    :priority,
    :tags,
    :due_date,
    :due_time,
    :started_at,
    :completed_at,
    :archived_at,
    :archive_reason,
    :recurrence_rule,
    :metadata,
    :assignee_id,
    :creator_id,
    :created_via_conversation_id,
    :parent_task_id,
    :recurrence_source_id
  ]

  def changeset(task, attrs) do
    task
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_length(:title, max: 500)
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:priority, @priorities)
    |> validate_inclusion(:archive_reason, @archive_reasons)
    |> unique_constraint(:short_id)
    |> check_constraint(:parent_task_id, name: :no_self_parent)
    |> foreign_key_constraint(:assignee_id)
    |> foreign_key_constraint(:creator_id)
    |> foreign_key_constraint(:created_via_conversation_id)
    |> foreign_key_constraint(:parent_task_id)
    |> foreign_key_constraint(:recurrence_source_id)
  end
end
