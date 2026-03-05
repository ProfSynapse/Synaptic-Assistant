defmodule Assistant.Schemas.UserSkillOverride do
  @moduledoc """
  Per-user skill enable/disable override.

  Stores a user's personal preference for whether a specific skill can be used.
  This is layered on top of the global skill policy.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Assistant.Skills.Registry

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @required_fields [:user_id, :skill_name, :enabled]

  schema "user_skill_overrides" do
    field :skill_name, :string
    field :enabled, :boolean, default: true

    belongs_to :user, Assistant.Schemas.User

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(override, attrs) do
    override
    |> cast(attrs, @required_fields)
    |> validate_required(@required_fields)
    |> validate_length(:skill_name, min: 1, max: 255)
    |> validate_change(:skill_name, &validate_known_skill/2)
    |> foreign_key_constraint(:user_id)
    |> unique_constraint([:user_id, :skill_name],
      name: :user_skill_overrides_user_skill_unique
    )
  end

  defp validate_known_skill(:skill_name, skill_name) do
    known_names = Registry.list_all() |> Enum.map(& &1.name) |> MapSet.new()

    if MapSet.member?(known_names, skill_name) do
      []
    else
      [skill_name: "is not a recognized skill"]
    end
  end
end
