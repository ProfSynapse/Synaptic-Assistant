defmodule Assistant.Schemas.Message do
  @moduledoc """
  Message schema. Stores individual messages within a conversation.
  Role enum expanded for tool-calling traces: user, assistant, system,
  tool_call, tool_result.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @roles ~w(user assistant system tool_call tool_result)

  schema "messages" do
    field :role, :string
    field :content, :string
    field :tool_calls, :map
    field :tool_results, :map
    field :token_count, :integer

    # Sub-agent trace: links to the parent execution that spawned this message
    field :parent_execution_id, :binary_id

    belongs_to :conversation, Assistant.Schemas.Conversation

    timestamps(type: :utc_datetime_usec)
  end

  @required_fields [:role, :conversation_id]
  @optional_fields [:content, :tool_calls, :tool_results, :token_count, :parent_execution_id]

  def changeset(message, attrs) do
    message
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:role, @roles)
    |> foreign_key_constraint(:conversation_id)
  end
end
