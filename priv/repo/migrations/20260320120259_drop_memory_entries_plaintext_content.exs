defmodule Assistant.Repo.Migrations.DropMemoryEntriesPlaintextContent do
  use Ecto.Migration

  def up do
    alter table(:memory_entries) do
      remove :content, :text
    end

    # Update the search vector trigger to exclude the dropped content column
    execute("DROP FUNCTION IF EXISTS memory_entries_search_text_trigger() CASCADE")

    execute("""
    CREATE FUNCTION memory_entries_search_text_trigger() RETURNS trigger AS $$
    BEGIN
      NEW.search_text :=
        setweight(to_tsvector('english', coalesce(NEW.title, '')), 'A') ||
        setweight(to_tsvector('english', coalesce(array_to_string(NEW.search_queries, ' '), '')), 'C');
      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql
    """)

    execute("""
    CREATE TRIGGER trg_memory_entries_search_text
      BEFORE INSERT OR UPDATE ON memory_entries
      FOR EACH ROW
      EXECUTE FUNCTION memory_entries_search_text_trigger()
    """)
  end

  def down do
    alter table(:memory_entries) do
      add :content, :text
    end

    # Restore the search vector trigger with content column
    execute("DROP FUNCTION IF EXISTS memory_entries_search_text_trigger() CASCADE")

    execute("""
    CREATE FUNCTION memory_entries_search_text_trigger() RETURNS trigger AS $$
    BEGIN
      NEW.search_text :=
        setweight(to_tsvector('english', coalesce(NEW.title, '')), 'A') ||
        setweight(to_tsvector('english', coalesce(NEW.content, '')), 'B') ||
        setweight(to_tsvector('english', coalesce(array_to_string(NEW.search_queries, ' '), '')), 'C');
      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql
    """)

    execute("""
    CREATE TRIGGER trg_memory_entries_search_text
      BEFORE INSERT OR UPDATE ON memory_entries
      FOR EACH ROW
      EXECUTE FUNCTION memory_entries_search_text_trigger()
    """)
  end
end
