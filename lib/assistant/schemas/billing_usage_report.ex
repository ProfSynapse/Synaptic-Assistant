defmodule Assistant.Schemas.BillingUsageReport do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "billing_usage_reports" do
    field :period_start, :utc_datetime_usec
    field :period_end, :utc_datetime_usec
    field :sample_count, :integer, default: 0
    field :average_total_bytes, :integer, default: 0
    field :average_overage_bytes, :integer, default: 0
    field :reported_overage_units, :integer, default: 0
    field :stripe_meter_event_identifier, :string
    field :reported_at, :utc_datetime_usec

    belongs_to :billing_account, Assistant.Schemas.BillingAccount

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def changeset(report, attrs) do
    report
    |> cast(attrs, [
      :billing_account_id,
      :period_start,
      :period_end,
      :sample_count,
      :average_total_bytes,
      :average_overage_bytes,
      :reported_overage_units,
      :stripe_meter_event_identifier,
      :reported_at
    ])
    |> validate_required([
      :billing_account_id,
      :period_start,
      :period_end,
      :sample_count,
      :average_total_bytes,
      :average_overage_bytes,
      :reported_overage_units
    ])
    |> validate_number(:sample_count, greater_than_or_equal_to: 0)
    |> validate_number(:average_total_bytes, greater_than_or_equal_to: 0)
    |> validate_number(:average_overage_bytes, greater_than_or_equal_to: 0)
    |> validate_number(:reported_overage_units, greater_than_or_equal_to: 0)
    |> unique_constraint([:billing_account_id, :period_start, :period_end],
      name: :billing_usage_reports_account_period_index
    )
    |> unique_constraint(:stripe_meter_event_identifier,
      name: :billing_usage_reports_meter_event_identifier_index
    )
  end
end
