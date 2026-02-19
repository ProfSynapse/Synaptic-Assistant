defmodule Assistant.Schemas.MemoryEntityRelation do
  @moduledoc """
  Directed relationship between two memory entities.
  Examples: "works_at", "manages", "related_to", "part_of".

  Relations use temporal validity: never deleted, only closed by setting
  `valid_to`. Active relations have `valid_to IS NULL`. This preserves
  full fact history for the entity graph.

  Each relation carries a confidence score (0-1) and optional provenance
  linking back to the memory entry that established it.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @relation_types ~w(works_at works_with manages reports_to part_of owns related_to located_in supersedes)

  schema "memory_entity_relations" do
    field :relation_type, :string
    field :metadata, :map, default: %{}
    field :valid_from, :utc_datetime_usec
    field :valid_to, :utc_datetime_usec
    field :confidence, :decimal, default: Decimal.new("0.80")

    belongs_to :source_entity, Assistant.Schemas.MemoryEntity
    belongs_to :target_entity, Assistant.Schemas.MemoryEntity
    belongs_to :source_memory_entry, Assistant.Schemas.MemoryEntry

    timestamps(type: :utc_datetime_usec)
  end

  @required_fields [:relation_type, :source_entity_id, :target_entity_id]
  @optional_fields [:metadata, :valid_from, :valid_to, :confidence, :source_memory_entry_id]

  def relation_types, do: @relation_types

  def changeset(relation, attrs) do
    relation
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:relation_type, @relation_types)
    |> validate_number(:confidence, greater_than_or_equal_to: 0, less_than_or_equal_to: 1)
    |> maybe_set_valid_from()
    |> unique_constraint([:source_entity_id, :target_entity_id, :relation_type],
      name: :memory_entity_relations_active_unique
    )
    |> check_constraint(:source_entity_id, name: :no_self_relation)
    |> foreign_key_constraint(:source_entity_id)
    |> foreign_key_constraint(:target_entity_id)
    |> foreign_key_constraint(:source_memory_entry_id)
  end

  defp maybe_set_valid_from(changeset) do
    case get_field(changeset, :valid_from) do
      nil -> put_change(changeset, :valid_from, DateTime.utc_now())
      _existing -> changeset
    end
  end
end
