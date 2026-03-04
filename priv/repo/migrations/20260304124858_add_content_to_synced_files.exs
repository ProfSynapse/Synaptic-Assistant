defmodule Assistant.Repo.Migrations.AddContentToSyncedFiles do
  use Ecto.Migration

  def change do
    alter table(:synced_files) do
      add :content, :binary
    end
  end
end
