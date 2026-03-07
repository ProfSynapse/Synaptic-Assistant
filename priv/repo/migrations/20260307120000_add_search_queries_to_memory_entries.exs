defmodule Assistant.Repo.Migrations.AddSearchQueriesToMemoryEntries do
  use Ecto.Migration

  def up do
    # 1. Add the search_queries column
    alter table(:memory_entries) do
      add :search_queries, {:array, :text}, default: [], null: false
    end

    # 2. Drop the existing GIN index on search_text
    execute "DROP INDEX IF EXISTS idx_memory_entries_search"

    # 3. Drop the existing generated search_text column
    execute "ALTER TABLE memory_entries DROP COLUMN IF EXISTS search_text"

    # 4. Re-create search_text as a generated tsvector combining content + search_queries
    execute """
    ALTER TABLE memory_entries ADD COLUMN search_text tsvector GENERATED ALWAYS AS (
      to_tsvector('english', coalesce(content, '')) ||
      to_tsvector('english', coalesce(array_to_string(search_queries, ' '), ''))
    ) STORED
    """

    # 5. Re-create the GIN index
    execute "CREATE INDEX idx_memory_entries_search ON memory_entries USING gin(search_text)"
  end

  def down do
    # Drop the GIN index
    execute "DROP INDEX IF EXISTS idx_memory_entries_search"

    # Drop the combined search_text column
    execute "ALTER TABLE memory_entries DROP COLUMN IF EXISTS search_text"

    # Re-create the original content-only search_text column
    execute """
    ALTER TABLE memory_entries ADD COLUMN search_text tsvector GENERATED ALWAYS AS (
      to_tsvector('english', coalesce(content, ''))
    ) STORED
    """

    # Re-create the GIN index
    execute "CREATE INDEX idx_memory_entries_search ON memory_entries USING gin(search_text)"

    # Drop the search_queries column
    alter table(:memory_entries) do
      remove :search_queries
    end
  end
end
