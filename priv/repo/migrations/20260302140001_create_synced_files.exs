defmodule Assistant.Repo.Migrations.CreateSyncedFiles do
  use Ecto.Migration

  def change do
    create table(:synced_files, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false

      add :drive_file_id, :string, null: false
      add :drive_file_name, :string, null: false
      add :drive_mime_type, :string, null: false
      add :local_path, :string, null: false
      add :local_format, :string, null: false
      add :remote_modified_at, :utc_datetime_usec
      add :local_modified_at, :utc_datetime_usec
      add :remote_checksum, :string
      add :local_checksum, :string
      add :sync_status, :string, null: false, default: "synced"
      add :last_synced_at, :utc_datetime_usec
      add :sync_error, :text
      add :drive_id, :string

      timestamps(type: :utc_datetime_usec)
    end

    # One sync record per file per user
    create unique_index(:synced_files, [:user_id, :drive_file_id])

    # Efficient queries for conflict/error states
    create index(:synced_files, [:user_id, :sync_status])

    create constraint(:synced_files, :valid_sync_status,
             check:
               "sync_status IN ('synced', 'local_ahead', 'remote_ahead', 'conflict', 'error')"
           )

    create constraint(:synced_files, :valid_local_format,
             check: "local_format IN ('md', 'csv', 'txt', 'json')"
           )
  end
end
