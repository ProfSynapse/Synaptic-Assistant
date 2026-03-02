defmodule Assistant.Repo.Migrations.CreateSyncHistory do
  use Ecto.Migration

  def change do
    create table(:sync_history, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :synced_file_id, references(:synced_files, type: :binary_id, on_delete: :delete_all),
        null: false

      add :operation, :string, null: false
      add :details, :map, default: %{}

      # Append-only: only inserted_at, no updated_at
      add :inserted_at, :utc_datetime_usec, null: false, default: fragment("now()")
    end

    create index(:sync_history, [:synced_file_id])
    create index(:sync_history, [:inserted_at])

    create constraint(:sync_history, :valid_operation,
             check:
               "operation IN ('download', 'upload', 'conflict_detect', 'conflict_resolve', 'delete_local', 'trash', 'untrash', 'error')"
           )
  end
end
