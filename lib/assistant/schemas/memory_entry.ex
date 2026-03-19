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
    field :title, :string
    field :content, :string
    field :content_encrypted, :map
    field :tags, {:array, :string}, default: []
    field :search_queries, {:array, :string}, default: []
    field :category, :string
    field :source_type, :string
    field :importance, :decimal, default: Decimal.new("0.50")
    field :embedding_model, :string
    field :decay_factor, :decimal, default: Decimal.new("1.00")
    field :accessed_at, :utc_datetime_usec

    # search_text is a trigger-populated tsvector column (read-only in Elixir)

    # Progressive disclosure: which message range this memory covers
    field :segment_start_message_id, :binary_id
    field :segment_end_message_id, :binary_id

    belongs_to :user, Assistant.Schemas.User
    belongs_to :source_conversation, Assistant.Schemas.Conversation

    field :embedding, Pgvector.Ecto.Vector
    field :access_count, :integer, default: 0

    has_many :entity_mentions, Assistant.Schemas.MemoryEntityMention

    timestamps(type: :utc_datetime_usec)
  end

  @required_fields [:content, :title]
  @optional_fields [
    :tags,
    :search_queries,
    :category,
    :source_type,
    :importance,
    :embedding_model,
    :decay_factor,
    :accessed_at,
    :user_id,
    :source_conversation_id,
    :segment_start_message_id,
    :segment_end_message_id,
    :embedding,
    :access_count
  ]

  def changeset(memory_entry, attrs) do
    memory_entry
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> normalize_title()
    |> maybe_put_generated_title()
    |> validate_required(@required_fields)
    |> validate_length(:title, max: 160)
    |> validate_inclusion(:source_type, @source_types)
    |> validate_number(:importance, greater_than_or_equal_to: 0, less_than_or_equal_to: 1)
    |> validate_number(:decay_factor, greater_than_or_equal_to: 0, less_than_or_equal_to: 1.5)
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:source_conversation_id)
    |> check_constraint(:source_type, name: :valid_source_type)
  end

  defp maybe_put_generated_title(changeset) do
    case {get_field(changeset, :title), get_field(changeset, :content)} do
      {title, _content} when is_binary(title) and title != "" ->
        changeset

      {_title, content} when is_binary(content) ->
        put_change(changeset, :title, derive_title(content))

      _ ->
        changeset
    end
  end

  defp normalize_title(changeset) do
    update_change(changeset, :title, fn
      nil -> nil
      title -> String.trim(title)
    end)
  end

  defp derive_title(content) do
    content
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> String.slice(0, 160)
    |> case do
      "" -> "Untitled memory"
      title -> title
    end
  end
end
