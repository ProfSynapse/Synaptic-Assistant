defmodule Assistant.Schemas.TaskComment do
  @moduledoc """
  Task comment schema. Comments on tasks, authored by users or the
  assistant (author_id null = assistant-authored).
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "task_comments" do
    field :content, :string

    belongs_to :task, Assistant.Schemas.Task
    belongs_to :author, Assistant.Schemas.User
    belongs_to :source_conversation, Assistant.Schemas.Conversation

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @required_fields [:content, :task_id]
  @optional_fields [:author_id, :source_conversation_id]

  def changeset(comment, attrs) do
    comment
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> foreign_key_constraint(:task_id)
    |> foreign_key_constraint(:author_id)
    |> foreign_key_constraint(:source_conversation_id)
  end
end
