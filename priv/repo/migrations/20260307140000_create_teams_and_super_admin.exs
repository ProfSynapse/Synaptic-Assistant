defmodule Assistant.Repo.Migrations.CreateTeamsAndSuperAdmin do
  use Ecto.Migration

  def change do
    # Create teams table
    create table(:teams, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :description, :text

      timestamps(type: :utc_datetime)
    end

    create unique_index(:teams, [:name])

    # Add is_super_admin and team_id to settings_users
    alter table(:settings_users) do
      add :is_super_admin, :boolean, default: false, null: false
      add :team_id, references(:teams, type: :binary_id, on_delete: :nilify_all)
    end

    create index(:settings_users, [:team_id])

    # Add team_id to allowlist entries
    alter table(:settings_user_allowlist_entries) do
      add :team_id, references(:teams, type: :binary_id, on_delete: :nilify_all)
    end

    # Migrate existing admins to super_admin
    # Any user who bootstrapped admin gets super_admin status
    execute(
      "UPDATE settings_users SET is_super_admin = true WHERE is_admin = true",
      "UPDATE settings_users SET is_super_admin = false"
    )
  end
end
