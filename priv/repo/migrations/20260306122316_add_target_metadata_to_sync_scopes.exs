defmodule Assistant.Repo.Migrations.AddTargetMetadataToSyncScopes do
  use Ecto.Migration

  def change do
    alter table(:sync_scopes) do
      add :scope_type, :string, null: false, default: "folder"
      add :file_id, :string
      add :file_name, :string
      add :file_mime_type, :string
    end

    execute(
      """
      UPDATE sync_scopes
      SET scope_type =
        CASE
          WHEN folder_id IS NULL THEN 'drive'
          ELSE 'folder'
        END
      """,
      "UPDATE sync_scopes SET scope_type = 'folder'"
    )

    drop_if_exists index(:sync_scopes, [:user_id, :drive_id, :folder_id],
                     name: :sync_scopes_user_drive_folder_unique
                   )

    drop_if_exists index(:sync_scopes, [:user_id, :drive_id],
                     name: :sync_scopes_user_drive_all_unique
                   )

    drop_if_exists index(:sync_scopes, [:user_id, :folder_id],
                     name: :sync_scopes_user_personal_folder_unique
                   )

    drop_if_exists index(:sync_scopes, [:user_id], name: :sync_scopes_user_personal_all_unique)

    create unique_index(:sync_scopes, [:user_id, :drive_id, :folder_id],
             name: :sync_scopes_user_drive_folder_unique,
             where: "drive_id IS NOT NULL AND folder_id IS NOT NULL AND scope_type != 'file'"
           )

    create unique_index(:sync_scopes, [:user_id, :drive_id],
             name: :sync_scopes_user_drive_all_unique,
             where: "drive_id IS NOT NULL AND folder_id IS NULL AND scope_type != 'file'"
           )

    create unique_index(:sync_scopes, [:user_id, :folder_id],
             name: :sync_scopes_user_personal_folder_unique,
             where: "drive_id IS NULL AND folder_id IS NOT NULL AND scope_type != 'file'"
           )

    create unique_index(:sync_scopes, [:user_id],
             name: :sync_scopes_user_personal_all_unique,
             where: "drive_id IS NULL AND folder_id IS NULL AND scope_type != 'file'"
           )

    create unique_index(:sync_scopes, [:user_id, :drive_id, :file_id],
             name: :sync_scopes_user_drive_file_unique,
             where: "drive_id IS NOT NULL AND scope_type = 'file' AND file_id IS NOT NULL"
           )

    create unique_index(:sync_scopes, [:user_id, :file_id],
             name: :sync_scopes_user_personal_file_unique,
             where: "drive_id IS NULL AND scope_type = 'file' AND file_id IS NOT NULL"
           )

    create constraint(:sync_scopes, :valid_scope_type,
             check: "scope_type IN ('drive', 'folder', 'file')"
           )
  end
end
