defmodule Assistant.Schemas.MemoryEntity do
  @moduledoc """
  Memory entity schema. Represents a named entity (person, project,
  concept) extracted from conversations and memories. Part of the
  entity graph for "show me everything related to X" queries.

  Entities are scoped per user — "Bob" for user A and "Bob" for user B
  are distinct entities with separate relation graphs.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @entity_types ~w(person organization project concept location)

  schema "memory_entities" do
    field :name, :string
    field :entity_type, :string
    field :metadata, :map, default: %{}

    belongs_to :user, Assistant.Schemas.User

    has_many :mentions, Assistant.Schemas.MemoryEntityMention, foreign_key: :entity_id

    has_many :outgoing_relations, Assistant.Schemas.MemoryEntityRelation,
      foreign_key: :source_entity_id

    has_many :incoming_relations, Assistant.Schemas.MemoryEntityRelation,
      foreign_key: :target_entity_id

    timestamps(type: :utc_datetime_usec)
  end

  @required_fields [:name, :entity_type, :user_id]
  @optional_fields [:metadata]

  def changeset(entity, attrs) do
    entity
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:entity_type, @entity_types)
    |> unique_constraint([:user_id, :name, :entity_type])
    |> foreign_key_constraint(:user_id)
  end
end
