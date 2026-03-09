defmodule Assistant.Schemas.SpendingLimit do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "spending_limits" do
    field :budget_cents, :integer
    field :period, :string, default: "monthly"
    field :reset_day, :integer, default: 1
    field :hard_cap, :boolean, default: true
    field :warning_threshold, :integer, default: 80

    belongs_to :settings_user, Assistant.Accounts.SettingsUser

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  @required_fields [:budget_cents]
  @optional_fields [:period, :reset_day, :hard_cap, :warning_threshold, :settings_user_id]

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(spending_limit, attrs) do
    spending_limit
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_number(:budget_cents, greater_than: 0)
    |> validate_inclusion(:period, ["monthly"])
    |> validate_number(:reset_day, greater_than_or_equal_to: 1, less_than_or_equal_to: 28)
    |> validate_number(:warning_threshold,
      greater_than_or_equal_to: 1,
      less_than_or_equal_to: 100
    )
    |> foreign_key_constraint(:settings_user_id)
    |> unique_constraint(:settings_user_id)
  end
end
