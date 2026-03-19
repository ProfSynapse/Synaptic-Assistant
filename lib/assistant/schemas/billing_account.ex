defmodule Assistant.Schemas.BillingAccount do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @plans ~w(free pro)
  @billing_modes ~w(standard complimentary manual)

  schema "billing_accounts" do
    field :name, :string
    field :plan, :string, default: "free"
    field :billing_mode, :string, default: "standard"
    field :billing_email, :string
    field :complimentary_until, :utc_datetime
    field :seat_bonus, :integer, default: 0
    field :storage_bonus_bytes, :integer, default: 0
    field :internal_notes, :string
    field :stripe_customer_id, :string
    field :stripe_subscription_id, :string
    field :stripe_subscription_item_id, :string
    field :stripe_subscription_status, :string
    field :stripe_price_id, :string
    field :stripe_current_period_end, :utc_datetime

    has_many :settings_users, Assistant.Accounts.SettingsUser
    has_many :users, Assistant.Schemas.User
    has_many :usage_snapshots, Assistant.Schemas.BillingUsageSnapshot
    has_many :usage_reports, Assistant.Schemas.BillingUsageReport

    timestamps(type: :utc_datetime)
  end

  def changeset(billing_account, attrs) do
    billing_account
    |> cast(attrs, [
      :name,
      :plan,
      :billing_mode,
      :billing_email,
      :complimentary_until,
      :seat_bonus,
      :storage_bonus_bytes,
      :internal_notes,
      :stripe_customer_id,
      :stripe_subscription_id,
      :stripe_subscription_item_id,
      :stripe_subscription_status,
      :stripe_price_id,
      :stripe_current_period_end
    ])
    |> validate_required([:name, :plan])
    |> validate_length(:name, max: 160)
    |> validate_length(:billing_email, max: 160)
    |> validate_length(:internal_notes, max: 2_000)
    |> validate_inclusion(:plan, @plans)
    |> validate_inclusion(:billing_mode, @billing_modes)
    |> validate_number(:seat_bonus, greater_than_or_equal_to: 0)
    |> validate_number(:storage_bonus_bytes, greater_than_or_equal_to: 0)
    |> unique_constraint(:stripe_customer_id)
    |> unique_constraint(:stripe_subscription_id)
  end
end
