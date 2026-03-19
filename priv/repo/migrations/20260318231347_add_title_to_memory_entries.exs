defmodule Assistant.Repo.Migrations.AddTitleToMemoryEntries do
  use Ecto.Migration

  def up do
    alter table(:memory_entries) do
      add :title, :text
    end

    execute("""
    UPDATE memory_entries
    SET title = COALESCE(
      NULLIF(
        LEFT(
          REGEXP_REPLACE(
            SPLIT_PART(COALESCE(content, ''), E'\\n', 1),
            '\\s+',
            ' ',
            'g'
          ),
          160
        ),
        ''
      ),
      'Untitled memory'
    )
    """)

    execute("ALTER TABLE memory_entries ALTER COLUMN title SET NOT NULL")

    execute("DROP TRIGGER IF EXISTS trg_memory_entries_search_text ON memory_entries")
    execute("DROP FUNCTION IF EXISTS memory_entries_search_text_trigger()")

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

    execute("""
    UPDATE memory_entries SET search_text =
      setweight(to_tsvector('english', coalesce(title, '')), 'A') ||
      setweight(to_tsvector('english', coalesce(content, '')), 'B') ||
      setweight(to_tsvector('english', coalesce(array_to_string(search_queries, ' '), '')), 'C')
    """)
  end

  def down do
    execute("DROP TRIGGER IF EXISTS trg_memory_entries_search_text ON memory_entries")
    execute("DROP FUNCTION IF EXISTS memory_entries_search_text_trigger()")

    execute("""
    CREATE FUNCTION memory_entries_search_text_trigger() RETURNS trigger AS $$
    BEGIN
      NEW.search_text :=
        to_tsvector('english', coalesce(NEW.content, '')) ||
        to_tsvector('english', coalesce(array_to_string(NEW.search_queries, ' '), ''));
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

    execute("""
    UPDATE memory_entries SET search_text =
      to_tsvector('english', coalesce(content, '')) ||
      to_tsvector('english', coalesce(array_to_string(search_queries, ' '), ''))
    """)

    alter table(:memory_entries) do
      remove :title
    end
  end
end
