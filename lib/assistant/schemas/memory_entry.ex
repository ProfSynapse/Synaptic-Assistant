defmodule Assistant.Schemas.MemoryEntry do
  @moduledoc """
  Memory entry schema. Stores long-term memories with tags, categories,
  full-text search vector, and optional embedding for hybrid retrieval.
  Supports progressive disclosure via segment message ID references.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @source_types ~w(conversation skill_execution user_explicit system agent_result)

  schema "memory_entries" do
    field :content, :string
    field :tags, {:array, :string}, default: []
    field :category, :string
    field :source_type, :string
    field :importance, :decimal, default: Decimal.new("0.50")
    field :embedding_model, :string
    field :decay_factor, :decimal, default: Decimal.new("1.00")
    field :accessed_at, :utc_datetime_usec

    # search_text is a generated tsvector column (read-only in Elixir)

    # Progressive disclosure: which message range this memory covers
    field :segment_start_message_id, :binary_id
    field :segment_end_message_id, :binary_id

    belongs_to :user, Assistant.Schemas.User
    belongs_to :source_conversation, Assistant.Schemas.Conversation

    has_many :entity_mentions, Assistant.Schemas.MemoryEntityMention

    timestamps(type: :utc_datetime_usec)
  end

  @required_fields [:content]
  @optional_fields [
    :tags,
    :category,
    :source_type,
    :importance,
    :embedding_model,
    :decay_factor,
    :accessed_at,
    :user_id,
    :source_conversation_id,
    :segment_start_message_id,
    :segment_end_message_id
  ]

  def changeset(memory_entry, attrs) do
    memory_entry
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:source_type, @source_types)
    |> validate_number(:importance, greater_than_or_equal_to: 0, less_than_or_equal_to: 1)
    |> validate_number(:decay_factor, greater_than_or_equal_to: 0, less_than_or_equal_to: 1)
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:source_conversation_id)
    |> check_constraint(:source_type, name: :valid_source_type)
  end
end
