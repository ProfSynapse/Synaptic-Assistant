defmodule Assistant.Repo.Migrations.AddBillingAccountsAndSettingsUserBillingAccount do
  use Ecto.Migration

  def up do
    create table(:billing_accounts, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :plan, :string, null: false, default: "free"
      add :billing_email, :string
      add :stripe_customer_id, :string
      add :stripe_subscription_id, :string
      add :stripe_subscription_item_id, :string
      add :stripe_subscription_status, :string
      add :stripe_price_id, :string
      add :stripe_current_period_end, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:billing_accounts, [:stripe_customer_id])
    create unique_index(:billing_accounts, [:stripe_subscription_id])

    alter table(:settings_users) do
      add :billing_account_id,
          references(:billing_accounts, type: :binary_id, on_delete: :nilify_all)

      add :billing_role, :string, null: false, default: "member"
    end

    create index(:settings_users, [:billing_account_id])
  end

  def down do
    drop_if_exists index(:settings_users, [:billing_account_id])

    alter table(:settings_users) do
      remove_if_exists :billing_account_id
      remove_if_exists :billing_role
    end

    drop_if_exists index(:billing_accounts, [:stripe_subscription_id])
    drop_if_exists index(:billing_accounts, [:stripe_customer_id])
    drop_if_exists table(:billing_accounts)
  end
end
