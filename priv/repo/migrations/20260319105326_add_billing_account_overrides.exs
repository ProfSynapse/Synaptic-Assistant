defmodule Assistant.Repo.Migrations.AddBillingAccountOverrides do
  use Ecto.Migration

  def change do
    alter table(:billing_accounts) do
      add :billing_mode, :string, null: false, default: "standard"
      add :complimentary_until, :utc_datetime
      add :seat_bonus, :integer, null: false, default: 0
      add :storage_bonus_bytes, :bigint, null: false, default: 0
      add :internal_notes, :text
    end
  end
end
