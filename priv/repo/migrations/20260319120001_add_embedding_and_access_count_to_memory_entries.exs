defmodule Assistant.Repo.Migrations.AddEmbeddingAndAccessCountToMemoryEntries do
  use Ecto.Migration

  def change do
    alter table(:memory_entries) do
      add :embedding, :vector, size: 384
      add :access_count, :integer, default: 0, null: false
    end

    create index(:memory_entries, [:embedding],
      using: "hnsw",
      options: "WITH (m = 16, ef_construction = 64)",
      where: "embedding IS NOT NULL",
      name: :memory_entries_embedding_hnsw_index
    )
  end
end
