defmodule Assistant.Repo.Migrations.AddFolderInfrastructure do
  use Ecto.Migration

  def change do
    # Add parent folder reference to synced_files
    alter table(:synced_files) do
      add :parent_folder_id, :string
      add :parent_folder_name, :string
    end

    create index(:synced_files, [:parent_folder_id])
    create index(:synced_files, [:user_id, :parent_folder_id])

    # Create document_folders table (folder nodes for activation model)
    create table(:document_folders, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :drive_folder_id, :string, null: false
      add :drive_id, :string
      add :name, :string, null: false
      add :embedding, :vector, size: 384
      add :activation_boost, :float, default: 1.0
      add :child_count, :integer, default: 0

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:document_folders, [:user_id, :drive_folder_id])

    execute(
      "CREATE INDEX document_folders_embedding_hnsw_index ON document_folders USING hnsw (embedding vector_cosine_ops) WITH (m = 16, ef_construction = 64) WHERE embedding IS NOT NULL",
      "DROP INDEX IF EXISTS document_folders_embedding_hnsw_index"
    )
  end
end
