defmodule Assistant.Repo.Migrations.AddSyncHistoryCompositeIndex do
  use Ecto.Migration

  def change do
    # Drop the single-column index and replace with a composite index
    # covering the common query pattern: history for a file ordered by time
    drop index(:sync_history, [:synced_file_id])
    create index(:sync_history, [:synced_file_id, :inserted_at])
  end
end
