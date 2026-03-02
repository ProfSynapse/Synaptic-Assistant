defmodule Assistant.Repo.Migrations.AddFileSizeToSyncedFiles do
  use Ecto.Migration

  def change do
    alter table(:synced_files) do
      add :file_size, :bigint
    end
  end
end
