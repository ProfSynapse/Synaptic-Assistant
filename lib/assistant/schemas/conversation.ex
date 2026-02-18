defmodule Assistant.Schemas.Conversation do
  @moduledoc """
  Conversation schema. Each conversation belongs to a user and channel.
  Includes summary fields for continuous compaction (incremental fold).
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses ~w(active idle closed)
  @agent_types ~w(orchestrator sub_agent)

  schema "conversations" do
    field :channel, :string
    field :started_at, :utc_datetime_usec
    field :last_active_at, :utc_datetime_usec
    field :status, :string, default: "active"
    field :metadata, :map, default: %{}

    # Continuous compaction fields
    field :summary, :string
    field :summary_version, :integer, default: 0
    field :summary_model, :string

    # Sub-agent hierarchy
    field :agent_type, :string, default: "orchestrator"
    belongs_to :parent_conversation, __MODULE__

    belongs_to :user, Assistant.Schemas.User

    has_many :messages, Assistant.Schemas.Message
    has_many :child_conversations, __MODULE__, foreign_key: :parent_conversation_id

    timestamps(type: :utc_datetime_usec)
  end

  @required_fields [:channel, :user_id]
  @optional_fields [
    :started_at,
    :last_active_at,
    :status,
    :metadata,
    :summary,
    :summary_version,
    :summary_model,
    :agent_type,
    :parent_conversation_id
  ]

  def changeset(conversation, attrs) do
    conversation
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:agent_type, @agent_types)
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:parent_conversation_id)
  end

  @doc """
  Returns the root conversation_id by walking up the parent chain.

  For orchestrator conversations (parent_conversation_id is nil), returns
  the conversation's own id. For sub-agent conversations, returns the
  parent's id (sub-agents are only one level deep for now).

  This is used by memory entries to ensure all memories reference the
  root conversation for unified retrieval across the agent hierarchy.
  """
  @spec root_conversation_id(%__MODULE__{}) :: binary()
  def root_conversation_id(%__MODULE__{parent_conversation_id: nil, id: id}), do: id
  def root_conversation_id(%__MODULE__{parent_conversation_id: parent_id}), do: parent_id
end
