defmodule Assistant.Schemas.UserSkillOverride do
  @moduledoc """
  Per-user skill enable/disable override.

  Stores a user's personal preference for whether a specific skill can be used.
  This is layered on top of the global skill policy.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @required_fields [:user_id, :skill_name, :enabled]
  @type t :: %__MODULE__{}

  schema "user_skill_overrides" do
    field :skill_name, :string
    field :enabled, :boolean, default: true

    belongs_to :user, Assistant.Schemas.User

    timestamps(type: :utc_datetime_usec)
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(override, attrs) do
    override
    |> cast(attrs, @required_fields)
    |> validate_required(@required_fields)
    |> validate_length(:skill_name, min: 1, max: 255)
    |> foreign_key_constraint(:user_id)
    |> unique_constraint([:user_id, :skill_name],
      name: :user_skill_overrides_user_skill_unique
    )
  end
end
