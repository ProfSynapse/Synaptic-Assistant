defmodule Assistant.Repo.Migrations.AddSearchQueriesToMemoryEntries do
  use Ecto.Migration

  def up do
    # 1. Add the search_queries column
    alter table(:memory_entries) do
      add :search_queries, {:array, :text}, default: [], null: false
    end

    # 2. Drop the existing GIN index on search_text
    execute "DROP INDEX IF EXISTS idx_memory_entries_search"

    # 3. Drop the existing trigger and trigger function (from create_core_tables)
    execute "DROP TRIGGER IF EXISTS trg_memory_entries_search_text ON memory_entries"
    execute "DROP FUNCTION IF EXISTS memory_entries_search_text_trigger()"

    # 4. Drop the existing search_text column
    execute "ALTER TABLE memory_entries DROP COLUMN IF EXISTS search_text"

    # 5. Add search_text as a regular tsvector column (NOT generated)
    execute "ALTER TABLE memory_entries ADD COLUMN search_text tsvector"

    # 6. Create trigger function combining content + search_queries
    execute """
    CREATE FUNCTION memory_entries_search_text_trigger() RETURNS trigger AS $$
    BEGIN
      NEW.search_text :=
        to_tsvector('english', coalesce(NEW.content, '')) ||
        to_tsvector('english', coalesce(array_to_string(NEW.search_queries, ' '), ''));
      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql
    """

    # 7. Create the trigger
    execute """
    CREATE TRIGGER trg_memory_entries_search_text
      BEFORE INSERT OR UPDATE ON memory_entries
      FOR EACH ROW
      EXECUTE FUNCTION memory_entries_search_text_trigger()
    """

    # 8. Backfill existing rows
    execute """
    UPDATE memory_entries SET search_text =
      to_tsvector('english', coalesce(content, '')) ||
      to_tsvector('english', coalesce(array_to_string(search_queries, ' '), ''))
    """

    # 9. Re-create the GIN index
    execute "CREATE INDEX idx_memory_entries_search ON memory_entries USING gin(search_text)"
  end

  def down do
    # Drop the GIN index
    execute "DROP INDEX IF EXISTS idx_memory_entries_search"

    # Drop the combined trigger and function
    execute "DROP TRIGGER IF EXISTS trg_memory_entries_search_text ON memory_entries"
    execute "DROP FUNCTION IF EXISTS memory_entries_search_text_trigger()"

    # Drop the search_text column
    execute "ALTER TABLE memory_entries DROP COLUMN IF EXISTS search_text"

    # Re-create the original content-only search_text column (trigger-based)
    execute "ALTER TABLE memory_entries ADD COLUMN search_text tsvector"

    execute """
    CREATE FUNCTION memory_entries_search_text_trigger() RETURNS trigger AS $$
    BEGIN
      NEW.search_text := to_tsvector('english', coalesce(NEW.content, ''));
      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql
    """

    execute """
    CREATE TRIGGER trg_memory_entries_search_text
      BEFORE INSERT OR UPDATE ON memory_entries
      FOR EACH ROW
      EXECUTE FUNCTION memory_entries_search_text_trigger()
    """

    # Backfill with content-only tsvector
    execute """
    UPDATE memory_entries SET search_text =
      to_tsvector('english', coalesce(content, ''))
    """

    # Re-create the GIN index
    execute "CREATE INDEX idx_memory_entries_search ON memory_entries USING gin(search_text)"

    # Drop the search_queries column
    alter table(:memory_entries) do
      remove :search_queries
    end
  end
end
