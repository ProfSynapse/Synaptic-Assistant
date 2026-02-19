defmodule Assistant.Schemas.SkillConfig do
  @moduledoc """
  Skill configuration schema. Stores per-skill enable/disable state
  and configuration overrides as JSONB.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "skill_configs" do
    field :skill_id, :string
    field :enabled, :boolean, default: true
    field :config, :map, default: %{}

    timestamps(type: :utc_datetime_usec)
  end

  @required_fields [:skill_id]
  @optional_fields [:enabled, :config]

  def changeset(skill_config, attrs) do
    skill_config
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> unique_constraint(:skill_id)
  end
end
