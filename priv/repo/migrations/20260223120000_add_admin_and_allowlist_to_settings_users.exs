defmodule Assistant.Repo.Migrations.AddAdminAndAllowlistToSettingsUsers do
  use Ecto.Migration

  def change do
    alter table(:settings_users) do
      add :is_admin, :boolean, null: false, default: false
      add :access_scopes, {:array, :string}, null: false, default: []
    end

    create table(:settings_user_allowlist_entries, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :email, :citext, null: false
      add :active, :boolean, null: false, default: true
      add :is_admin, :boolean, null: false, default: false
      add :scopes, {:array, :string}, null: false, default: []
      add :notes, :text

      add :created_by_settings_user_id,
          references(:settings_users, type: :binary_id, on_delete: :nilify_all)

      add :updated_by_settings_user_id,
          references(:settings_users, type: :binary_id, on_delete: :nilify_all)

      timestamps(type: :utc_datetime)
    end

    create unique_index(:settings_user_allowlist_entries, [:email])
    create index(:settings_user_allowlist_entries, [:active])
  end
end
