defmodule Assistant.Repo.Migrations.AddEmbeddingAndAccessCountToMemoryEntries do
  use Ecto.Migration

  def change do
    alter table(:memory_entries) do
      add :embedding, :vector, size: 384
      add :access_count, :integer, default: 0, null: false
    end

    execute(
      "CREATE INDEX memory_entries_embedding_hnsw_index ON memory_entries USING hnsw (embedding vector_cosine_ops) WITH (m = 16, ef_construction = 64) WHERE embedding IS NOT NULL",
      "DROP INDEX IF EXISTS memory_entries_embedding_hnsw_index"
    )
  end
end
