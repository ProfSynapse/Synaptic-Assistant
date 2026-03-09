defmodule Assistant.Repo.Migrations.CreateUsageRecords do
  use Ecto.Migration

  def change do
    create table(:usage_records, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :settings_user_id,
          references(:settings_users, type: :binary_id, on_delete: :delete_all), null: false

      add :period_start, :date, null: false
      add :period_end, :date, null: false
      add :total_cost_cents, :integer, default: 0
      add :total_prompt_tokens, :bigint, default: 0
      add :total_completion_tokens, :bigint, default: 0
      add :call_count, :integer, default: 0

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:usage_records, [:settings_user_id, :period_start])
    create index(:usage_records, [:settings_user_id])
  end
end
