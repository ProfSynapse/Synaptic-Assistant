# Database Engineer Review: PR #1 — Schema Design and Migrations

**Reviewer**: Database Engineer
**Date**: 2026-02-18
**Scope**: All Ecto schemas (`lib/assistant/schemas/`) and migrations (`priv/repo/migrations/`)

---

## Summary

The database layer is well-structured. 18 tables across 3 migrations follow a logical dependency order, use UUID primary keys consistently, and enforce data integrity via CHECK constraints, unique indexes, and foreign key relationships. The memory entity graph hardening migration (temporal validity, user scoping, confidence/provenance) is a particularly mature pattern. There are no blocking issues. Findings below are organized by severity.

---

## Blocking Issues

None.

---

## Minor Issues

### M1. `memory_entities.user_id` added as `NOT NULL` without default in migration 3

**File**: `priv/repo/migrations/20260218140000_harden_memory_entity_graph.exs:20`

The hardening migration adds `user_id` with `null: false` to `memory_entities`. Since migration 1 creates the table without `user_id`, any rows inserted between migration 1 and migration 3 would cause migration 3 to fail. In this PR all three migrations run together so this is not a runtime issue, but the pattern is fragile for future migration ordering or partial rollback scenarios. A safer pattern would be: add column as nullable, backfill, then alter to `NOT NULL`.

**Risk**: Low in current context (all migrations applied together), medium if migrations are ever applied individually in a staging pipeline.

### M2. `execution_logs.parent_execution_id` is a bare `binary_id` without FK constraint

**File**: `priv/repo/migrations/20260218120000_create_core_tables.exs:359` and `lib/assistant/schemas/execution_log.ex:25`

`parent_execution_id` on `execution_logs` is typed as `:binary_id` but has no foreign key reference back to `execution_logs` itself. Similarly, `messages.parent_execution_id` (line 80 of the same migration) has no FK to `execution_logs`. Both are partial indexes on `IS NOT NULL` which is good for lookups, but referential integrity relies entirely on the application layer.

**Risk**: Orphaned `parent_execution_id` references if the parent execution log row is deleted. Since `execution_logs` cascade-deletes with conversations, the risk is limited to manual deletions or bugs in cleanup code.

### M3. `notification_channels.config` stored as `:binary` — no encryption at DB level

**File**: `priv/repo/migrations/20260218120000_create_core_tables.exs:448` and `lib/assistant/schemas/notification_channel.ex:18`

The Ecto schema's `@moduledoc` mentions "encrypted binary via Cloak.Ecto" but the schema field type is plain `:binary`, and there is no `Cloak.Ecto.Binary` type declaration in the schema module. This means the field will store raw bytes as-is. If webhook URLs or API keys are stored here, they are unencrypted at rest.

**Risk**: Credentials stored in plaintext in the database. This overlaps with the security reviewer's domain but is called out here because the schema type declaration does not match the documented intent.

### M4. `conversations.valid_status` CHECK constraint does not include `agent_type` values from migration 2

**File**: `priv/repo/migrations/20260218120000_create_core_tables.exs:60-62` and `priv/repo/migrations/20260218130000_add_parent_conversation_to_conversations.exs:23-25`

This is not a bug — they are different CHECK constraints on different columns. Noted for clarity: `valid_status` constrains `status`, while `valid_agent_type` constrains `agent_type`. Both are correct and non-overlapping.

### M5. `memory_entity_relations` unique index replaced — potential for transient duplicate violation during migration

**File**: `priv/repo/migrations/20260218140000_harden_memory_entity_graph.exs:48-59`

Migration 3 drops the original unique index on `(source_entity_id, target_entity_id, relation_type)` and replaces it with a partial unique index scoped to `WHERE valid_to IS NULL`. Between the `drop` and `create`, there is a brief window with no uniqueness enforcement. Since migrations run in a transaction by default in Ecto, this is safe. Noted for documentation purposes only.

### M6. `task.short_id` generation is not enforced at the DB level

**File**: `priv/repo/migrations/20260218120000_create_core_tables.exs:216` and `lib/assistant/schemas/task.ex:50`

`short_id` is declared `null: false` in the migration but is listed in `@optional_fields` in the Ecto schema (line 50). This means the changeset does not require it, but the database will reject inserts without it. The `short_id` must be generated before insert by application logic, and if that logic fails, the error surfaces as a database constraint violation rather than a clear changeset validation error.

**Risk**: Low — the DB constraint catches it regardless. Better developer experience would come from either adding a DB default (e.g., a generated column or trigger) or moving `short_id` to `@required_fields` and generating it in the changeset.

---

## Future Considerations

### F1. No embedding vector column on `memory_entries`

**File**: `priv/repo/migrations/20260218120000_create_core_tables.exs:93-117`

The schema has `embedding_model` (line 106) to record which model produced an embedding, but there is no `embedding` vector column. For hybrid retrieval (full-text + semantic), this will require pgvector and a future migration to add a `vector(N)` column. The `search_text` tsvector column provides full-text search in the interim, which is appropriate for Phase 1.

### F2. No composite index on `(user_id, status)` for conversations

**File**: `priv/repo/migrations/20260218120000_create_core_tables.exs:64-66`

Indexes exist on `user_id` and `status` individually. The most common query pattern ("show active conversations for user X") would benefit from a composite index on `(user_id, status)`. Individual indexes work but the planner may do a bitmap AND which is slower than a composite scan.

### F3. `memory_entries.importance` and `decay_factor` precision not specified

**File**: `priv/repo/migrations/20260218120000_create_core_tables.exs:105-107`

Both columns use `:decimal` without precision/scale. PostgreSQL's `numeric` without precision is arbitrary-precision which is fine for correctness but has performance implications for sorting and comparison vs. a fixed `numeric(3,2)`. Given these are always 0.00-1.00 values, specifying precision would be a minor optimization.

### F4. No index on `memory_entries.accessed_at` for decay-based retrieval

**File**: `priv/repo/migrations/20260218120000_create_core_tables.exs:108`

If the memory system uses time-decay scoring (combining `importance`, `decay_factor`, and `accessed_at`), queries ordering by `accessed_at` will need an index. Currently there are indexes on `importance` and `inserted_at` but not `accessed_at`.

### F5. `file_versions` lacks a composite unique index on `(drive_file_id, version_number)`

**File**: `priv/repo/migrations/20260218120000_create_core_tables.exs:376-397`

Nothing prevents two `file_versions` rows with the same `drive_file_id` and `version_number`. A unique constraint here would enforce version number integrity at the database level.

### F6. Single monolithic migration for 18 tables

**File**: `priv/repo/migrations/20260218120000_create_core_tables.exs`

The first migration creates all 18 core tables in a single `change/0`. This is a pragmatic choice for a greenfield project (no partial rollback risk), but if any single table definition needs to be fixed in the future, rolling back this migration drops all tables. For Phase 1 this is acceptable; going forward, prefer smaller migration files.

### F7. `scheduled_tasks` lacks a unique constraint on `(user_id, skill_id, cron_expression)`

**File**: `priv/repo/migrations/20260218120000_create_core_tables.exs:479-496`

Nothing prevents duplicate scheduled tasks for the same user/skill/cron combination. Whether this is intentional (user wants multiple schedules for the same skill) should be clarified.

### F8. Temporal validity `valid_from` default uses `fragment("now()")` — Ecto-level default may drift

**File**: `priv/repo/migrations/20260218140000_harden_memory_entity_graph.exs:30` and `lib/assistant/schemas/memory_entity_relation.ex:56-60`

The migration sets `default: fragment("now()")` for `valid_from`, while the Ecto schema's `maybe_set_valid_from/1` falls back to `DateTime.utc_now()`. These two clocks (Postgres `now()` and Elixir `DateTime.utc_now()`) can differ by milliseconds depending on transaction timing. For an append-only temporal model, this is generally not a problem, but worth noting for precision-sensitive temporal queries.

---

## Positive Observations

1. **Consistent UUID primary keys**: All tables use `binary_id` with `primary_key: false` — uniform and clean.
2. **CHECK constraints on enums**: Every enum-like column (`status`, `role`, `priority`, `entity_type`, etc.) has a database-level CHECK constraint. This is the correct approach over relying solely on application-level validation.
3. **Partial indexes**: Good use of partial indexes throughout (e.g., `WHERE archived_at IS NULL` on tasks, `WHERE parent_execution_id IS NOT NULL` on messages, `WHERE valid_to IS NULL` on entity relations). These reduce index bloat and improve query performance for hot paths.
4. **Temporal validity model**: The `valid_from`/`valid_to` pattern on `memory_entity_relations` with a partial unique index scoped to active relations is a well-implemented slowly-changing-dimension approach. Historical records are preserved without bloating the active query path.
5. **Full-text search**: Generated tsvector columns on `memory_entries` and `tasks` with GIN indexes are a solid choice for Phase 1 search. Weighted vectors on tasks (title=A, description=B) provide ranking out of the box.
6. **GIN indexes on array columns**: Both `tags` columns have GIN indexes, enabling efficient `@>` (contains) queries.
7. **Self-referential FK constraints**: `no_self_parent` on tasks, `no_self_relation` on entity relations, `no_self_dependency` on task dependencies — all correctly enforced.
8. **Schema-migration alignment**: Ecto schema modules correctly mirror the database structure. `@required_fields`, `@optional_fields`, enum lists, and constraint names all match between schema and migration.
9. **`on_delete` strategy choices are well-reasoned**: `restrict` on users (prevent user deletion if conversations exist), `delete_all` on conversation-message cascade (delete conversation = delete messages), `nilify_all` on soft references (memory entries keep existing even if source conversation is removed).
10. **`usec` timestamps everywhere**: Microsecond precision for all timestamps is appropriate for an AI assistant where events can occur in rapid succession.

---

## Verdict

**Approve** — The database layer is solid for Phase 1. No blocking issues. The minor items (M1-M6) are low-risk and can be addressed in subsequent iterations. Future considerations (F1-F8) are tracked for when the relevant features land.
