defmodule Assistant.Repo.Migrations.DropPlaintextFieldsF0 do
  use Ecto.Migration

  def up do
    # 1. Update the search vector trigger to exclude description
    execute("""
      CREATE OR REPLACE FUNCTION tasks_search_vector_trigger() RETURNS trigger AS $$
      BEGIN
        NEW.search_vector := setweight(to_tsvector('english', coalesce(NEW.title, '')), 'A');
        RETURN NEW;
      END;
      $$ LANGUAGE plpgsql
    """)
    # Trigger the update for all existing rows
    execute("UPDATE tasks SET updated_at = updated_at")

    # 2. Drop the plaintext fields
    alter table(:messages) do
      remove :content
    end

    alter table(:tasks) do
      remove :description
    end

    alter table(:task_comments) do
      remove :content
    end

    alter table(:execution_logs) do
      remove :parameters
      remove :result
      remove :error_message
    end
  end

  def down do
    # Note: Down migration recreates the columns but DOES NOT restore plaintext data.
    # Data is lost unless a repair/backfill job decrypts and populates them.
    
    alter table(:execution_logs) do
      add :parameters, :map, default: %{}
      add :result, :map
      add :error_message, :text
    end

    alter table(:task_comments) do
      add :content, :text
    end

    alter table(:tasks) do
      add :description, :text
    end

    alter table(:messages) do
      add :content, :text
    end
    
    execute("""
      CREATE OR REPLACE FUNCTION tasks_search_vector_trigger() RETURNS trigger AS $$
      BEGIN
        NEW.search_vector :=
          setweight(to_tsvector('english', coalesce(NEW.title, '')), 'A') ||
          setweight(to_tsvector('english', coalesce(NEW.description, '')), 'B');
        RETURN NEW;
      END;
      $$ LANGUAGE plpgsql
    """)
    execute("UPDATE tasks SET updated_at = updated_at")
  end
end
