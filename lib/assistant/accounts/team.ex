defmodule Assistant.Accounts.Team do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "teams" do
    field :name, :string
    field :description, :string

    has_many :settings_users, Assistant.Accounts.SettingsUser

    timestamps(type: :utc_datetime)
  end

  def changeset(team, attrs) do
    team
    |> cast(attrs, [:name, :description])
    |> validate_required([:name])
    |> validate_length(:name, min: 1, max: 100)
    |> validate_format(:name, ~r/^[a-zA-Z0-9][a-zA-Z0-9 _-]*$/,
      message: "must start with a letter or number and contain only letters, numbers, spaces, hyphens, or underscores"
    )
    |> validate_length(:description, max: 500)
    |> unique_constraint(:name)
  end
end
