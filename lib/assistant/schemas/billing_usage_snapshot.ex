defmodule Assistant.Schemas.BillingUsageSnapshot do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "billing_usage_snapshots" do
    field :measured_at, :utc_datetime_usec
    field :seat_count, :integer, default: 0
    field :included_bytes, :integer, default: 0
    field :synced_file_bytes, :integer, default: 0
    field :message_bytes, :integer, default: 0
    field :memory_bytes, :integer, default: 0
    field :total_bytes, :integer, default: 0
    field :overage_bytes, :integer, default: 0

    belongs_to :billing_account, Assistant.Schemas.BillingAccount

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def changeset(snapshot, attrs) do
    snapshot
    |> cast(attrs, [
      :billing_account_id,
      :measured_at,
      :seat_count,
      :included_bytes,
      :synced_file_bytes,
      :message_bytes,
      :memory_bytes,
      :total_bytes,
      :overage_bytes
    ])
    |> validate_required([
      :billing_account_id,
      :measured_at,
      :seat_count,
      :included_bytes,
      :synced_file_bytes,
      :message_bytes,
      :memory_bytes,
      :total_bytes,
      :overage_bytes
    ])
    |> validate_number(:seat_count, greater_than_or_equal_to: 0)
    |> validate_number(:included_bytes, greater_than_or_equal_to: 0)
    |> validate_number(:synced_file_bytes, greater_than_or_equal_to: 0)
    |> validate_number(:message_bytes, greater_than_or_equal_to: 0)
    |> validate_number(:memory_bytes, greater_than_or_equal_to: 0)
    |> validate_number(:total_bytes, greater_than_or_equal_to: 0)
    |> validate_number(:overage_bytes, greater_than_or_equal_to: 0)
    |> unique_constraint([:billing_account_id, :measured_at],
      name: :billing_usage_snapshots_account_measured_at_index
    )
  end
end
