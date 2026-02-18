defmodule Assistant.Repo.Migrations.CreateCoreTables do
  @moduledoc """
  Creates all core application tables for the Skills-First AI Assistant.

  Migration order respects foreign key dependencies:
  1. users (no FK deps)
  2. conversations (-> users)
  3. messages (-> conversations)
  4. memory_entries (-> users, conversations, messages)
  5. memory_entities (no FK deps)
  6. memory_entity_relations (-> memory_entities)
  7. memory_entity_mentions (-> memory_entities, memory_entries)
  8. tasks (-> users, conversations, self-ref)
  9. task_dependencies (-> tasks)
  10. task_comments (-> tasks, users, conversations)
  11. task_history (-> tasks, users, conversations)
  12. execution_logs (-> conversations)
  13. file_versions (-> execution_logs)
  14. file_operation_logs (-> file_versions)
  15. skill_configs (no FK deps)
  16. notification_channels (no FK deps)
  17. notification_rules (-> notification_channels)
  18. scheduled_tasks (-> users)
  """
  use Ecto.Migration

  def change do
    # ── 1. users ──────────────────────────────────────────────────────
    create table(:users, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :external_id, :text, null: false
      add :channel, :text, null: false
      add :display_name, :text
      add :timezone, :text, null: false, default: "UTC"
      add :preferences, :map, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:users, [:external_id, :channel])

    # ── 2. conversations ──────────────────────────────────────────────
    create table(:conversations, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :restrict), null: false
      add :channel, :text, null: false
      add :started_at, :utc_datetime_usec
      add :last_active_at, :utc_datetime_usec
      add :status, :text, null: false, default: "active"
      add :metadata, :map, default: %{}

      # Continuous compaction fields
      add :summary, :text
      add :summary_version, :integer, default: 0
      add :summary_model, :text

      timestamps(type: :utc_datetime_usec)
    end

    create constraint(:conversations, :valid_status,
             check: "status IN ('active', 'idle', 'closed')"
           )

    create index(:conversations, [:user_id])
    create index(:conversations, [:status])
    create index(:conversations, [:last_active_at])

    # ── 3. messages ───────────────────────────────────────────────────
    create table(:messages, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :conversation_id, references(:conversations, type: :binary_id, on_delete: :delete_all),
        null: false

      add :role, :text, null: false
      add :content, :text
      add :tool_calls, :map
      add :tool_results, :map
      add :token_count, :integer
      add :parent_execution_id, :binary_id

      timestamps(type: :utc_datetime_usec)
    end

    create constraint(:messages, :valid_role,
             check: "role IN ('user', 'assistant', 'system', 'tool_call', 'tool_result')"
           )

    create index(:messages, [:conversation_id])
    create index(:messages, [:conversation_id, :inserted_at])
    create index(:messages, [:parent_execution_id], where: "parent_execution_id IS NOT NULL")

    # ── 4. memory_entries ─────────────────────────────────────────────
    create table(:memory_entries, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :nilify_all)

      add :source_conversation_id,
          references(:conversations, type: :binary_id, on_delete: :nilify_all)

      add :content, :text, null: false
      add :tags, {:array, :text}, default: []
      add :category, :text
      add :source_type, :text
      add :importance, :decimal, default: 0.50, null: false
      add :embedding_model, :text
      add :decay_factor, :decimal, default: 1.00, null: false
      add :accessed_at, :utc_datetime_usec

      # Progressive disclosure: message range this memory covers
      add :segment_start_message_id,
          references(:messages, type: :binary_id, on_delete: :nilify_all)

      add :segment_end_message_id, references(:messages, type: :binary_id, on_delete: :nilify_all)

      timestamps(type: :utc_datetime_usec)
    end

    create constraint(:memory_entries, :valid_source_type,
             check:
               "source_type IS NULL OR source_type IN ('conversation', 'skill_execution', 'user_explicit', 'system')"
           )

    # Generated tsvector column for full-text search
    execute(
      "ALTER TABLE memory_entries ADD COLUMN search_text tsvector GENERATED ALWAYS AS (to_tsvector('english', coalesce(content, ''))) STORED",
      "ALTER TABLE memory_entries DROP COLUMN search_text"
    )

    create index(:memory_entries, [:user_id])
    create index(:memory_entries, [:source_conversation_id])
    create index(:memory_entries, [:category])
    create index(:memory_entries, [:source_type])
    create index(:memory_entries, [:importance], order: [desc: :importance])
    create index(:memory_entries, [:inserted_at], order: [desc: :inserted_at])

    create index(:memory_entries, [:segment_start_message_id],
             where: "segment_start_message_id IS NOT NULL"
           )

    execute(
      "CREATE INDEX idx_memory_entries_search ON memory_entries USING gin(search_text)",
      "DROP INDEX idx_memory_entries_search"
    )

    execute(
      "CREATE INDEX idx_memory_entries_tags ON memory_entries USING gin(tags)",
      "DROP INDEX idx_memory_entries_tags"
    )

    # ── 5. memory_entities ────────────────────────────────────────────
    create table(:memory_entities, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :text, null: false
      add :entity_type, :text, null: false
      add :metadata, :map, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create constraint(:memory_entities, :valid_entity_type,
             check: "entity_type IN ('person', 'organization', 'project', 'concept', 'location')"
           )

    create unique_index(:memory_entities, [:name, :entity_type])

    # ── 6. memory_entity_relations ────────────────────────────────────
    create table(:memory_entity_relations, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :source_entity_id,
          references(:memory_entities, type: :binary_id, on_delete: :delete_all), null: false

      add :target_entity_id,
          references(:memory_entities, type: :binary_id, on_delete: :delete_all), null: false

      add :relation_type, :text, null: false
      add :metadata, :map, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create constraint(:memory_entity_relations, :no_self_relation,
             check: "source_entity_id != target_entity_id"
           )

    create unique_index(:memory_entity_relations, [
             :source_entity_id,
             :target_entity_id,
             :relation_type
           ])

    create index(:memory_entity_relations, [:source_entity_id])
    create index(:memory_entity_relations, [:target_entity_id])

    # ── 7. memory_entity_mentions ─────────────────────────────────────
    create table(:memory_entity_mentions, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :entity_id,
          references(:memory_entities, type: :binary_id, on_delete: :delete_all), null: false

      add :memory_entry_id,
          references(:memory_entries, type: :binary_id, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:memory_entity_mentions, [:entity_id, :memory_entry_id])
    create index(:memory_entity_mentions, [:entity_id])
    create index(:memory_entity_mentions, [:memory_entry_id])

    # ── 8. tasks ──────────────────────────────────────────────────────
    create table(:tasks, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :short_id, :text, null: false
      add :title, :text, null: false
      add :description, :text
      add :status, :text, null: false, default: "todo"
      add :priority, :text, null: false, default: "medium"
      add :tags, {:array, :text}, default: []
      add :due_date, :date
      add :due_time, :utc_datetime_usec
      add :started_at, :utc_datetime_usec
      add :completed_at, :utc_datetime_usec
      add :archived_at, :utc_datetime_usec
      add :archive_reason, :text
      add :recurrence_rule, :map
      add :metadata, :map, default: %{}

      add :assignee_id, references(:users, type: :binary_id, on_delete: :nilify_all)
      add :creator_id, references(:users, type: :binary_id, on_delete: :nilify_all)

      add :created_via_conversation_id,
          references(:conversations, type: :binary_id, on_delete: :nilify_all)

      add :parent_task_id, references(:tasks, type: :binary_id, on_delete: :nilify_all)
      add :recurrence_source_id, references(:tasks, type: :binary_id, on_delete: :nilify_all)

      timestamps(type: :utc_datetime_usec)
    end

    create constraint(:tasks, :valid_status,
             check: "status IN ('todo', 'in_progress', 'blocked', 'done', 'cancelled')"
           )

    create constraint(:tasks, :valid_priority,
             check: "priority IN ('critical', 'high', 'medium', 'low')"
           )

    create constraint(:tasks, :no_self_parent, check: "parent_task_id != id")

    # Generated tsvector column for full-text search on title + description
    execute(
      """
      ALTER TABLE tasks ADD COLUMN search_vector tsvector GENERATED ALWAYS AS (
        setweight(to_tsvector('english', coalesce(title, '')), 'A') ||
        setweight(to_tsvector('english', coalesce(description, '')), 'B')
      ) STORED
      """,
      "ALTER TABLE tasks DROP COLUMN search_vector"
    )

    create unique_index(:tasks, [:short_id])
    create index(:tasks, [:status], where: "archived_at IS NULL")
    create index(:tasks, [:assignee_id], where: "archived_at IS NULL")

    create index(:tasks, [:due_date],
             where: "archived_at IS NULL AND status NOT IN ('done', 'cancelled')"
           )

    create index(:tasks, [:priority], where: "archived_at IS NULL")
    create index(:tasks, [:parent_task_id])
    create index(:tasks, [:creator_id])
    create index(:tasks, [:created_via_conversation_id])
    create index(:tasks, [:inserted_at])
    create index(:tasks, [:recurrence_source_id], where: "recurrence_source_id IS NOT NULL")

    execute(
      "CREATE INDEX idx_tasks_search ON tasks USING gin(search_vector)",
      "DROP INDEX idx_tasks_search"
    )

    execute(
      "CREATE INDEX idx_tasks_tags ON tasks USING gin(tags)",
      "DROP INDEX idx_tasks_tags"
    )

    # ── 9. task_dependencies ──────────────────────────────────────────
    create table(:task_dependencies, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :blocking_task_id, references(:tasks, type: :binary_id, on_delete: :delete_all),
        null: false

      add :blocked_task_id, references(:tasks, type: :binary_id, on_delete: :delete_all),
        null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create constraint(:task_dependencies, :no_self_dependency,
             check: "blocking_task_id != blocked_task_id"
           )

    create unique_index(:task_dependencies, [:blocking_task_id, :blocked_task_id])
    create index(:task_dependencies, [:blocking_task_id])
    create index(:task_dependencies, [:blocked_task_id])

    # ── 10. task_comments ─────────────────────────────────────────────
    create table(:task_comments, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :task_id, references(:tasks, type: :binary_id, on_delete: :delete_all), null: false
      add :author_id, references(:users, type: :binary_id, on_delete: :nilify_all)

      add :source_conversation_id,
          references(:conversations, type: :binary_id, on_delete: :nilify_all)

      add :content, :text, null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:task_comments, [:task_id])

    # ── 11. task_history ──────────────────────────────────────────────
    create table(:task_history, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :task_id, references(:tasks, type: :binary_id, on_delete: :delete_all), null: false
      add :field_changed, :text, null: false
      add :old_value, :text
      add :new_value, :text
      add :changed_by_user_id, references(:users, type: :binary_id, on_delete: :nilify_all)

      add :changed_via_conversation_id,
          references(:conversations, type: :binary_id, on_delete: :nilify_all)

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:task_history, [:task_id])
    create index(:task_history, [:inserted_at])

    # ── 12. execution_logs ────────────────────────────────────────────
    create table(:execution_logs, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :conversation_id,
          references(:conversations, type: :binary_id, on_delete: :delete_all), null: false

      add :skill_id, :text, null: false
      add :parameters, :map, default: %{}
      add :result, :map
      add :status, :text, null: false, default: "pending"
      add :error_message, :text
      add :duration_ms, :integer
      add :started_at, :utc_datetime_usec
      add :completed_at, :utc_datetime_usec
      add :parent_execution_id, :binary_id

      timestamps(type: :utc_datetime_usec)
    end

    create constraint(:execution_logs, :valid_exec_status,
             check: "status IN ('pending', 'running', 'completed', 'failed', 'timeout')"
           )

    create index(:execution_logs, [:conversation_id])
    create index(:execution_logs, [:skill_id])
    create index(:execution_logs, [:status])

    create index(:execution_logs, [:parent_execution_id],
             where: "parent_execution_id IS NOT NULL"
           )

    # ── 13. file_versions ─────────────────────────────────────────────
    create table(:file_versions, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :skill_execution_id,
          references(:execution_logs, type: :binary_id, on_delete: :nilify_all)

      add :drive_file_id, :text, null: false
      add :drive_file_name, :text, null: false
      add :drive_folder_id, :text
      add :canonical_type, :text, null: false
      add :normalized_format, :text, null: false
      add :version_number, :integer, null: false, default: 1
      add :archive_file_id, :text
      add :archive_folder_id, :text
      add :checksum_before, :text
      add :checksum_after, :text
      add :operation, :text, null: false
      add :sync_status, :text, null: false, default: "synced"

      timestamps(type: :utc_datetime_usec)
    end

    create constraint(:file_versions, :valid_file_op,
             check: "operation IN ('create', 'update', 'archive', 'restore')"
           )

    create index(:file_versions, [:drive_file_id])
    create index(:file_versions, [:skill_execution_id])
    create index(:file_versions, [:sync_status])

    # ── 14. file_operation_logs ───────────────────────────────────────
    create table(:file_operation_logs, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :file_version_id,
          references(:file_versions, type: :binary_id, on_delete: :delete_all), null: false

      add :step, :text, null: false
      add :status, :text, null: false
      add :details, :map, default: %{}

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create constraint(:file_operation_logs, :valid_step,
             check: "step IN ('pull', 'manipulate', 'archive', 'verify', 'replace', 'record')"
           )

    create constraint(:file_operation_logs, :valid_step_status,
             check: "status IN ('started', 'completed', 'failed')"
           )

    create index(:file_operation_logs, [:file_version_id])

    # ── 15. skill_configs ─────────────────────────────────────────────
    create table(:skill_configs, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :skill_id, :text, null: false
      add :enabled, :boolean, null: false, default: true
      add :config, :map, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:skill_configs, [:skill_id])

    # ── 16. notification_channels ─────────────────────────────────────
    create table(:notification_channels, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :text, null: false
      add :type, :text, null: false
      add :config, :binary, null: false
      add :enabled, :boolean, null: false, default: true

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create constraint(:notification_channels, :valid_channel_type,
             check: "type IN ('google_chat_webhook', 'email', 'telegram')"
           )

    # ── 17. notification_rules ────────────────────────────────────────
    create table(:notification_rules, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :channel_id,
          references(:notification_channels, type: :binary_id, on_delete: :delete_all),
          null: false

      add :severity_min, :text, null: false, default: "error"
      add :component_filter, :text
      add :enabled, :boolean, null: false, default: true

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create constraint(:notification_rules, :valid_rule_severity,
             check: "severity_min IN ('info', 'warning', 'error', 'critical')"
           )

    create index(:notification_rules, [:channel_id])

    # ── 18. scheduled_tasks ───────────────────────────────────────────
    create table(:scheduled_tasks, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :skill_id, :text, null: false
      add :parameters, :map, default: %{}
      add :cron_expression, :text, null: false
      add :channel, :text, null: false
      add :timezone, :text, null: false, default: "UTC"
      add :enabled, :boolean, null: false, default: true
      add :last_run_at, :utc_datetime_usec
      add :next_run_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create index(:scheduled_tasks, [:next_run_at], where: "enabled = true")
    create index(:scheduled_tasks, [:user_id])
  end
end
