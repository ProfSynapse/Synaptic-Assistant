defmodule Assistant.Repo.Migrations.HardenMemoryEntityGraph do
  @moduledoc """
  Hardens the memory entity graph with four changes:

  1. User-scoped entities — adds user_id FK to memory_entities so
     "Bob" for user A and "Bob" for user B are distinct entities.
  2. Temporal validity — adds valid_from/valid_to to relations.
     Active relations have valid_to IS NULL. Relations are never
     deleted, only closed (valid_to = now()).
  3. Confidence + provenance — each relation carries a confidence
     score and optional link to the memory entry that established it.
  4. Relation type validation — CHECK constraint on relation_type
     against a predefined set (extensible by adding to the list).
  """
  use Ecto.Migration

  def change do
    # ── 1. User-scoped memory entities ──────────────────────────────
    alter table(:memory_entities) do
      add :user_id, references(:users, type: :binary_id, on_delete: :restrict), null: false
    end

    # Replace the old unique index with user-scoped version
    drop unique_index(:memory_entities, [:name, :entity_type])
    create unique_index(:memory_entities, [:user_id, :name, :entity_type])
    create index(:memory_entities, [:user_id])

    # ── 2. Temporal validity on relations ───────────────────────────
    alter table(:memory_entity_relations) do
      add :valid_from, :utc_datetime_usec, null: false, default: fragment("now()")
      add :valid_to, :utc_datetime_usec
    end

    # Partial index for efficient active-relation queries
    create index(:memory_entity_relations, [:source_entity_id],
      name: :memory_entity_relations_active_source_idx,
      where: "valid_to IS NULL"
    )

    create index(:memory_entity_relations, [:target_entity_id],
      name: :memory_entity_relations_active_target_idx,
      where: "valid_to IS NULL"
    )

    # Replace old unique index with one scoped to active relations only.
    # Multiple closed (valid_to IS NOT NULL) relations of the same type
    # between the same entities are allowed (historical records).
    drop unique_index(:memory_entity_relations, [
      :source_entity_id,
      :target_entity_id,
      :relation_type
    ])

    create unique_index(
      :memory_entity_relations,
      [:source_entity_id, :target_entity_id, :relation_type],
      name: :memory_entity_relations_active_unique,
      where: "valid_to IS NULL"
    )

    # ── 3. Confidence + provenance on relations ─────────────────────
    alter table(:memory_entity_relations) do
      add :confidence, :decimal, null: false, default: 0.80
      add :source_memory_entry_id,
          references(:memory_entries, type: :binary_id, on_delete: :nilify_all)
    end

    create index(:memory_entity_relations, [:source_memory_entry_id],
      where: "source_memory_entry_id IS NOT NULL"
    )

    # ── 4. Relation type validation ─────────────────────────────────
    create constraint(:memory_entity_relations, :valid_relation_type,
      check: """
      relation_type IN (
        'works_at', 'works_with', 'manages', 'reports_to',
        'part_of', 'owns', 'related_to', 'located_in', 'supersedes'
      )
      """
    )
  end
end
