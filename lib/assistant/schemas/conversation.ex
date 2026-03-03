defmodule Assistant.Schemas.Conversation do
  @moduledoc """
  Conversation schema. Each conversation belongs to a user and channel.
  Includes summary fields for continuous compaction (incremental fold).
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Assistant.Repo

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses ~w(active idle closed archived)
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

    # Compaction boundary tracking
    field :last_compacted_message_id, :binary_id

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
    :last_compacted_message_id,
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
    |> unique_constraint([:user_id, :agent_type],
      name: :conversations_user_active_agent_unique
    )
  end

  @doc """
  Returns the root conversation_id by walking up the parent chain.

  For orchestrator conversations (parent_conversation_id is nil), returns
  the conversation's own id. For single-level sub-agents, returns the
  parent's id directly (fast path — no DB query needed). For deeper
  nesting, falls back to a recursive DB query that walks up the chain.

  This is used by memory entries to ensure all memories reference the
  root conversation for unified retrieval across the agent hierarchy.
  """
  @spec root_conversation_id(%__MODULE__{}) :: binary()
  def root_conversation_id(%__MODULE__{parent_conversation_id: nil, id: id}), do: id

  def root_conversation_id(%__MODULE__{parent_conversation_id: parent_id}) do
    # Fast path: check if parent is already the root (1-level deep).
    # This avoids a query for the common case where sub-agents are
    # direct children of the orchestrator conversation.
    case Repo.get(__MODULE__, parent_id) do
      nil ->
        # Parent not found — return it as-is (defensive)
        parent_id

      %__MODULE__{parent_conversation_id: nil} ->
        # Parent has no parent — it's the root
        parent_id

      %__MODULE__{} ->
        # Deeper nesting — walk up the chain recursively via DB
        walk_to_root(parent_id)
    end
  end

  # Walks up the parent chain using a recursive PostgreSQL CTE.
  # Returns the root conversation_id (the one with no parent).
  # Max depth of 10 prevents infinite loops from circular references.
  defp walk_to_root(conversation_id) do
    query = """
    WITH RECURSIVE ancestors AS (
      SELECT id, parent_conversation_id, 1 AS depth
      FROM conversations
      WHERE id = $1
      UNION ALL
      SELECT c.id, c.parent_conversation_id, a.depth + 1
      FROM conversations c
      JOIN ancestors a ON a.parent_conversation_id = c.id
      WHERE a.parent_conversation_id IS NOT NULL AND a.depth < 10
    )
    SELECT id FROM ancestors
    WHERE parent_conversation_id IS NULL
    LIMIT 1
    """

    case Repo.query(query, [Ecto.UUID.dump!(conversation_id)]) do
      {:ok, %{rows: [[root_id]]}} ->
        Ecto.UUID.cast!(root_id)

      _ ->
        # Fallback: return the original conversation_id if query fails
        conversation_id
    end
  end
end
