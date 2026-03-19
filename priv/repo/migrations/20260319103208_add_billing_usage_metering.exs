defmodule Assistant.Repo.Migrations.AddBillingUsageMetering do
  use Ecto.Migration

  def up do
    alter table(:users) do
      add :billing_account_id,
          references(:billing_accounts, type: :binary_id, on_delete: :nilify_all)
    end

    create index(:users, [:billing_account_id])

    execute(
      """
      UPDATE users AS u
      SET billing_account_id = memberships.billing_account_id
      FROM (
        SELECT DISTINCT ON (user_id) user_id, billing_account_id
        FROM settings_users
        WHERE user_id IS NOT NULL
          AND billing_account_id IS NOT NULL
        ORDER BY user_id, inserted_at ASC
      ) AS memberships
      WHERE u.id = memberships.user_id
        AND u.billing_account_id IS DISTINCT FROM memberships.billing_account_id
      """,
      """
      UPDATE users
      SET billing_account_id = NULL
      """
    )

    create table(:billing_usage_snapshots, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :billing_account_id,
          references(:billing_accounts, type: :binary_id, on_delete: :delete_all),
          null: false

      add :measured_at, :utc_datetime_usec, null: false
      add :seat_count, :integer, null: false, default: 0
      add :included_bytes, :bigint, null: false, default: 0
      add :synced_file_bytes, :bigint, null: false, default: 0
      add :message_bytes, :bigint, null: false, default: 0
      add :memory_bytes, :bigint, null: false, default: 0
      add :total_bytes, :bigint, null: false, default: 0
      add :overage_bytes, :bigint, null: false, default: 0

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:billing_usage_snapshots, [:billing_account_id])

    create unique_index(:billing_usage_snapshots, [:billing_account_id, :measured_at],
             name: :billing_usage_snapshots_account_measured_at_index
           )

    create table(:billing_usage_reports, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :billing_account_id,
          references(:billing_accounts, type: :binary_id, on_delete: :delete_all),
          null: false

      add :period_start, :utc_datetime_usec, null: false
      add :period_end, :utc_datetime_usec, null: false
      add :sample_count, :integer, null: false, default: 0
      add :average_total_bytes, :bigint, null: false, default: 0
      add :average_overage_bytes, :bigint, null: false, default: 0
      add :reported_overage_units, :bigint, null: false, default: 0
      add :stripe_meter_event_identifier, :string
      add :reported_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:billing_usage_reports, [:billing_account_id])

    create unique_index(:billing_usage_reports, [:billing_account_id, :period_start, :period_end],
             name: :billing_usage_reports_account_period_index
           )

    create unique_index(:billing_usage_reports, [:stripe_meter_event_identifier],
             where: "stripe_meter_event_identifier IS NOT NULL",
             name: :billing_usage_reports_meter_event_identifier_index
           )
  end

  def down do
    drop_if_exists index(:billing_usage_reports, [:stripe_meter_event_identifier],
                     name: :billing_usage_reports_meter_event_identifier_index
                   )

    drop_if_exists index(
                     :billing_usage_reports,
                     [:billing_account_id, :period_start, :period_end],
                     name: :billing_usage_reports_account_period_index
                   )

    drop_if_exists index(:billing_usage_reports, [:billing_account_id])
    drop_if_exists table(:billing_usage_reports)

    drop_if_exists index(:billing_usage_snapshots, [:billing_account_id, :measured_at],
                     name: :billing_usage_snapshots_account_measured_at_index
                   )

    drop_if_exists index(:billing_usage_snapshots, [:billing_account_id])
    drop_if_exists table(:billing_usage_snapshots)

    drop_if_exists index(:users, [:billing_account_id])

    alter table(:users) do
      remove_if_exists :billing_account_id
    end
  end
end
