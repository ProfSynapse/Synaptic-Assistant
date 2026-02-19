defmodule Assistant.Repo.Migrations.CreateSettingsUsersAuthTables do
  use Ecto.Migration

  def change do
    execute "CREATE EXTENSION IF NOT EXISTS citext", ""

    create table(:settings_users, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :display_name, :string
      add :timezone, :string, null: false, default: "UTC"
      add :email, :citext, null: false
      add :hashed_password, :string
      add :confirmed_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:settings_users, [:email])

    create table(:settings_users_tokens, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :settings_user_id,
          references(:settings_users, type: :binary_id, on_delete: :delete_all), null: false

      add :token, :binary, null: false
      add :context, :string, null: false
      add :sent_to, :string
      add :authenticated_at, :utc_datetime

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:settings_users_tokens, [:settings_user_id])
    create unique_index(:settings_users_tokens, [:context, :token])
  end
end
