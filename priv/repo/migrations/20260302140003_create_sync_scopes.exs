defmodule Assistant.Repo.Migrations.CreateSyncScopes do
  use Ecto.Migration

  def change do
    create table(:sync_scopes, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false

      add :drive_id, :string
      # folder_id is NULL when scope covers the entire drive
      add :folder_id, :string
      add :folder_name, :string, null: false
      add :access_level, :string, null: false, default: "read_only"

      timestamps(type: :utc_datetime_usec)
    end

    # Four partial unique indexes covering all NULL combinations:

    # Shared drive + specific folder
    create unique_index(:sync_scopes, [:user_id, :drive_id, :folder_id],
             name: :sync_scopes_user_drive_folder_unique,
             where: "drive_id IS NOT NULL AND folder_id IS NOT NULL"
           )

    # Shared drive + entire drive (folder_id IS NULL)
    create unique_index(:sync_scopes, [:user_id, :drive_id],
             name: :sync_scopes_user_drive_all_unique,
             where: "drive_id IS NOT NULL AND folder_id IS NULL"
           )

    # Personal drive + specific folder
    create unique_index(:sync_scopes, [:user_id, :folder_id],
             name: :sync_scopes_user_personal_folder_unique,
             where: "drive_id IS NULL AND folder_id IS NOT NULL"
           )

    # Personal drive + entire drive (both NULL)
    create unique_index(:sync_scopes, [:user_id],
             name: :sync_scopes_user_personal_all_unique,
             where: "drive_id IS NULL AND folder_id IS NULL"
           )

    create index(:sync_scopes, [:user_id])

    create constraint(:sync_scopes, :valid_access_level,
             check: "access_level IN ('read_only', 'read_write')"
           )
  end
end
