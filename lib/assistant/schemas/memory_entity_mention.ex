defmodule Assistant.Schemas.MemoryEntityMention do
  @moduledoc """
  Links a memory entity to a memory entry where it was mentioned.
  Enables reverse lookups: "which memories mention entity X?"
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "memory_entity_mentions" do
    belongs_to :entity, Assistant.Schemas.MemoryEntity
    belongs_to :memory_entry, Assistant.Schemas.MemoryEntry

    timestamps(type: :utc_datetime_usec)
  end

  @required_fields [:entity_id, :memory_entry_id]

  def changeset(mention, attrs) do
    mention
    |> cast(attrs, @required_fields)
    |> validate_required(@required_fields)
    |> unique_constraint([:entity_id, :memory_entry_id])
    |> foreign_key_constraint(:entity_id)
    |> foreign_key_constraint(:memory_entry_id)
  end
end
