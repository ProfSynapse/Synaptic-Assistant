defmodule Assistant.Repo.Migrations.CreateSpendingLimits do
  use Ecto.Migration

  def change do
    create table(:spending_limits, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :settings_user_id,
          references(:settings_users, type: :binary_id, on_delete: :delete_all), null: false

      add :budget_cents, :integer, null: false
      add :period, :string, default: "monthly"
      add :reset_day, :integer, default: 1
      add :hard_cap, :boolean, default: true
      add :warning_threshold, :integer, default: 80

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:spending_limits, [:settings_user_id])
  end
end
