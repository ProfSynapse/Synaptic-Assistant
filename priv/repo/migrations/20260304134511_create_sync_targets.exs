defmodule Assistant.Repo.Migrations.CreateSyncTargets do
  use Ecto.Migration

  def change do
    create table(:sync_targets, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, on_delete: :delete_all, type: :binary_id), null: false
      # "drive", "folder", "file"
      add :target_type, :string, null: false
      # Google Drive ID (can be null for personal My Drive)
      add :target_id, :string
      add :target_name, :string, null: false
      add :enabled, :boolean, default: true, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:sync_targets, [:user_id])

    # User shouldn't add the same target twice
    create unique_index(:sync_targets, [:user_id, :target_id],
             name: :sync_targets_user_id_target_id_index,
             where: "target_id IS NOT NULL"
           )

    # For personal drive where target_id might be null
    create unique_index(:sync_targets, [:user_id, :target_type],
             name: :sync_targets_user_id_personal_drive_index,
             where: "target_type = 'drive' AND target_id IS NULL"
           )
  end
end
