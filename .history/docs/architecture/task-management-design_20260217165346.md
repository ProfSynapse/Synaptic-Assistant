# Task Management System: Architectural Design

> Part of the Skills-First AI Assistant architecture.
> Planning only — no implementation.

## 1. Overview

Task management is a **first-class internal skill domain** — it lives in PostgreSQL alongside conversations and memories, not behind an external API. The assistant exposes task operations as skills the LLM can invoke, making it natural for the assistant to create, track, and manage work items during conversations.

The design must balance two priorities:
- **LLM ergonomics**: The tool schemas must be intuitive enough that the LLM can reliably translate natural language into structured operations
- **Query power**: The filter system must support complex queries (overdue tasks for user X with tag "Q1") without requiring the LLM to write SQL

---

## 2. Data Schema

### 2.1 Core Tables

#### tasks

```sql
CREATE TABLE tasks (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  -- Content
  title VARCHAR(500) NOT NULL,
  description TEXT,

  -- Classification
  status VARCHAR(20) NOT NULL DEFAULT 'todo',
  priority VARCHAR(10) NOT NULL DEFAULT 'medium',
  tags TEXT[] DEFAULT '{}',

  -- Assignment
  assignee_id UUID REFERENCES users(id),
  creator_id UUID REFERENCES users(id),
  created_via_conversation_id UUID REFERENCES conversations(id),

  -- Scheduling
  due_date DATE,
  due_time TIMESTAMPTZ,         -- optional precise time (for calendar-linked tasks)
  started_at TIMESTAMPTZ,
  completed_at TIMESTAMPTZ,

  -- Hierarchy
  parent_task_id UUID REFERENCES tasks(id),

  -- Recurrence (nullable — only set for recurring templates)
  recurrence_rule JSONB,        -- e.g. {"frequency": "weekly", "interval": 1, "day_of_week": "monday"}
  recurrence_source_id UUID REFERENCES tasks(id),  -- links generated instance to its template

  -- Soft delete
  archived_at TIMESTAMPTZ,
  archive_reason VARCHAR(50),   -- 'completed', 'cancelled', 'superseded'

  -- Search
  search_vector tsvector GENERATED ALWAYS AS (
    setweight(to_tsvector('english', coalesce(title, '')), 'A') ||
    setweight(to_tsvector('english', coalesce(description, '')), 'B')
  ) STORED,

  -- Metadata
  metadata JSONB DEFAULT '{}',  -- extensible key-value (links to HubSpot deals, Drive files, etc.)
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  CONSTRAINT valid_status CHECK (status IN ('todo', 'in_progress', 'blocked', 'done', 'cancelled')),
  CONSTRAINT valid_priority CHECK (priority IN ('critical', 'high', 'medium', 'low')),
  CONSTRAINT no_self_parent CHECK (parent_task_id != id)
);

-- Performance indexes
CREATE INDEX idx_tasks_status ON tasks(status) WHERE archived_at IS NULL;
CREATE INDEX idx_tasks_assignee ON tasks(assignee_id) WHERE archived_at IS NULL;
CREATE INDEX idx_tasks_due_date ON tasks(due_date) WHERE archived_at IS NULL AND status NOT IN ('done', 'cancelled');
CREATE INDEX idx_tasks_priority ON tasks(priority) WHERE archived_at IS NULL;
CREATE INDEX idx_tasks_parent ON tasks(parent_task_id);
CREATE INDEX idx_tasks_tags ON tasks USING gin(tags);
CREATE INDEX idx_tasks_search ON tasks USING gin(search_vector);
CREATE INDEX idx_tasks_created_at ON tasks(created_at);
CREATE INDEX idx_tasks_recurrence_source ON tasks(recurrence_source_id) WHERE recurrence_source_id IS NOT NULL;
```

#### task_dependencies

```sql
CREATE TABLE task_dependencies (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  blocking_task_id UUID NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
  blocked_task_id UUID NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE(blocking_task_id, blocked_task_id),
  CONSTRAINT no_self_dependency CHECK (blocking_task_id != blocked_task_id)
);

CREATE INDEX idx_task_deps_blocking ON task_dependencies(blocking_task_id);
CREATE INDEX idx_task_deps_blocked ON task_dependencies(blocked_task_id);
```

#### task_comments

```sql
CREATE TABLE task_comments (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  task_id UUID NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
  author_id UUID REFERENCES users(id),   -- null = assistant-authored
  content TEXT NOT NULL,
  source_conversation_id UUID REFERENCES conversations(id),
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_task_comments_task ON task_comments(task_id);
```

#### task_history

```sql
CREATE TABLE task_history (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  task_id UUID NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
  field_changed VARCHAR(50) NOT NULL,
  old_value TEXT,
  new_value TEXT,
  changed_by_user_id UUID REFERENCES users(id),  -- null = assistant
  changed_via_conversation_id UUID REFERENCES conversations(id),
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_task_history_task ON task_history(task_id);
CREATE INDEX idx_task_history_created ON task_history(created_at);
```

### 2.2 Schema Design Decisions

**Status model**: Five states cover the full lifecycle without over-engineering.

```
todo --> in_progress --> done
  |         |             |
  |         v             v
  |      blocked       (archived)
  |         |
  v         v
cancelled  (archived)
```

- `todo`: Not started
- `in_progress`: Actively being worked on
- `blocked`: Cannot proceed (dependency or external blocker)
- `done`: Completed successfully
- `cancelled`: Abandoned (soft delete via `archived_at`)

**Priority model**: Four levels — `critical`, `high`, `medium`, `low`. Simple, universally understood. Avoids numeric scales that confuse LLMs.

**Tags as array**: PostgreSQL `TEXT[]` with GIN index. This is more natural for LLMs than a separate tags table — the LLM can pass `["Q1", "backend", "urgent"]` directly. No join needed for queries.

**Subtasks via `parent_task_id`**: Single-level hierarchy is sufficient. Deep nesting creates confusion for LLMs. If a task has a parent, it is a subtask. Subtasks inherit the parent's due date if their own is null.

**Dependencies via `task_dependencies`**: Separate table for many-to-many blocking relationships. A task with unresolved blocking dependencies shows as `blocked` status. The assistant should automatically check dependencies when marking tasks as `in_progress`.

**Recurrence via `recurrence_rule` JSONB**: Template tasks have a `recurrence_rule`. The scheduler generates concrete task instances from templates. Each generated task links back via `recurrence_source_id` for audit.

**Soft delete via `archived_at`**: Tasks are never hard-deleted. "Delete" sets `archived_at` and `archive_reason`. All active queries filter `WHERE archived_at IS NULL`.

**Full-text search via `tsvector`**: Generated column combines title (weight A) and description (weight B) for ranked text search. Supports natural language queries like "Q1 marketing report".

**History tracking**: Every field change is logged to `task_history`. This enables the assistant to answer "what changed on this task?" and feeds into the memory system.

---

## 3. Skill Interface Design

### 3.1 Approach: Separate Skills Per Operation

**Decision**: Use separate skills for each operation rather than a single "tasks" skill with sub-operations.

**Rationale**:
- CLI-first command execution works best with focused, single-purpose skills
- The LLM can select the right tool more reliably when each has a clear, distinct purpose
- Parameter schemas are simpler and more specific per operation
- Follows the same pattern as other domains (separate skills for `email.send`, `email.read`, `email.search`)

### 3.2 Tool Definitions

#### tasks.create

```elixir
defmodule Assistant.Skills.Tasks.Create do
  @behaviour Assistant.Skills.Skill

  @impl true
  def tool_definition do
    %{
      name: "tasks.create",
      description: "Create a new task. Use this when the user wants to track a piece of work, an action item, a reminder, or a to-do.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "title" => %{
            "type" => "string",
            "description" => "Short, actionable title for the task"
          },
          "description" => %{
            "type" => "string",
            "description" => "Detailed description of what needs to be done. Optional."
          },
          "priority" => %{
            "type" => "string",
            "enum" => ["critical", "high", "medium", "low"],
            "description" => "Task priority. Defaults to medium if not specified."
          },
          "due_date" => %{
            "type" => "string",
            "description" => "Due date in YYYY-MM-DD format. Optional."
          },
          "assignee" => %{
            "type" => "string",
            "description" => "Name or identifier of the person assigned. Optional — defaults to the requesting user."
          },
          "tags" => %{
            "type" => "array",
            "items" => %{"type" => "string"},
            "description" => "Tags for categorization, e.g. ['backend', 'Q1', 'urgent']. Optional."
          },
          "parent_task_id" => %{
            "type" => "string",
            "description" => "UUID of parent task if this is a subtask. Optional."
          }
        },
        "required" => ["title"]
      }
    }
  end

  @impl true
  def domain, do: :tasks

  @impl true
  def isolation_level, do: :none
end
```

#### tasks.search

```elixir
defmodule Assistant.Skills.Tasks.Search do
  @behaviour Assistant.Skills.Skill

  @impl true
  def tool_definition do
    %{
      name: "tasks.search",
      description: "Search and filter tasks. Use this to find tasks by status, assignee, due date, priority, tags, or text search. Returns a list of matching tasks.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "query" => %{
            "type" => "string",
            "description" => "Free text search across task titles and descriptions. Optional."
          },
          "status" => %{
            "type" => "array",
            "items" => %{
              "type" => "string",
              "enum" => ["todo", "in_progress", "blocked", "done", "cancelled"]
            },
            "description" => "Filter by status(es). Multiple values = OR. Default: ['todo', 'in_progress', 'blocked'] (active tasks)."
          },
          "assignee" => %{
            "type" => "string",
            "description" => "Filter by assignee name. Optional."
          },
          "priority" => %{
            "type" => "array",
            "items" => %{
              "type" => "string",
              "enum" => ["critical", "high", "medium", "low"]
            },
            "description" => "Filter by priority level(s). Optional."
          },
          "tags" => %{
            "type" => "array",
            "items" => %{"type" => "string"},
            "description" => "Filter by tags. Tasks must have ALL specified tags. Optional."
          },
          "due_before" => %{
            "type" => "string",
            "description" => "Show tasks due on or before this date (YYYY-MM-DD). Optional."
          },
          "due_after" => %{
            "type" => "string",
            "description" => "Show tasks due on or after this date (YYYY-MM-DD). Optional."
          },
          "overdue" => %{
            "type" => "boolean",
            "description" => "If true, only show tasks past their due date that aren't done. Optional."
          },
          "include_subtasks" => %{
            "type" => "boolean",
            "description" => "If true, include subtasks in results. Default: true."
          },
          "sort_by" => %{
            "type" => "string",
            "enum" => ["due_date", "priority", "created_at", "updated_at"],
            "description" => "Sort results. Default: due_date (nearest first)."
          },
          "limit" => %{
            "type" => "integer",
            "description" => "Maximum number of results. Default: 20."
          }
        },
        "required" => []
      }
    }
  end

  @impl true
  def domain, do: :tasks

  @impl true
  def isolation_level, do: :none
end
```

#### tasks.update

```elixir
defmodule Assistant.Skills.Tasks.Update do
  @behaviour Assistant.Skills.Skill

  @impl true
  def tool_definition do
    %{
      name: "tasks.update",
      description: "Update an existing task. Change status, priority, assignee, due date, tags, or description. Use for marking tasks done, reassigning, reprioritizing, etc.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "task_id" => %{
            "type" => "string",
            "description" => "UUID of the task to update"
          },
          "status" => %{
            "type" => "string",
            "enum" => ["todo", "in_progress", "blocked", "done", "cancelled"],
            "description" => "New status. Optional."
          },
          "title" => %{
            "type" => "string",
            "description" => "New title. Optional."
          },
          "description" => %{
            "type" => "string",
            "description" => "New description. Optional."
          },
          "priority" => %{
            "type" => "string",
            "enum" => ["critical", "high", "medium", "low"],
            "description" => "New priority. Optional."
          },
          "due_date" => %{
            "type" => "string",
            "description" => "New due date (YYYY-MM-DD) or null to remove. Optional."
          },
          "assignee" => %{
            "type" => "string",
            "description" => "New assignee name or identifier. Optional."
          },
          "tags" => %{
            "type" => "array",
            "items" => %{"type" => "string"},
            "description" => "Replace all tags with this list. Optional."
          },
          "add_tags" => %{
            "type" => "array",
            "items" => %{"type" => "string"},
            "description" => "Tags to add (without removing existing). Optional."
          },
          "remove_tags" => %{
            "type" => "array",
            "items" => %{"type" => "string"},
            "description" => "Tags to remove. Optional."
          },
          "add_comment" => %{
            "type" => "string",
            "description" => "Add a comment to the task. Optional."
          }
        },
        "required" => ["task_id"]
      }
    }
  end

  @impl true
  def domain, do: :tasks

  @impl true
  def isolation_level, do: :none
end
```

#### tasks.delete (archive)

```elixir
defmodule Assistant.Skills.Tasks.Delete do
  @behaviour Assistant.Skills.Skill

  @impl true
  def tool_definition do
    %{
      name: "tasks.delete",
      description: "Archive (soft delete) a task. The task is not permanently deleted — it moves to the archive. Use when a task is no longer relevant.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "task_id" => %{
            "type" => "string",
            "description" => "UUID of the task to archive"
          },
          "reason" => %{
            "type" => "string",
            "enum" => ["completed", "cancelled", "superseded"],
            "description" => "Why the task is being archived. Default: cancelled."
          }
        },
        "required" => ["task_id"]
      }
    }
  end

  @impl true
  def domain, do: :tasks

  @impl true
  def isolation_level, do: :none
end
```

#### tasks.get

```elixir
defmodule Assistant.Skills.Tasks.Get do
  @behaviour Assistant.Skills.Skill

  @impl true
  def tool_definition do
    %{
      name: "tasks.get",
      description: "Get task details by ID, multiple IDs, or recency. Use this for explicit retrieval (single task, known task set, or recent tasks) with optional expanded details.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "task_id" => %{
            "type" => "string",
            "description" => "UUID of a single task to retrieve. Optional if task_ids or recent is provided."
          },
          "task_ids" => %{
            "type" => "array",
            "items" => %{"type" => "string"},
            "description" => "List of task UUIDs to retrieve in one call. Optional."
          },
          "recent" => %{
            "type" => "boolean",
            "description" => "If true, return recent tasks (defaults to current user's tasks). Optional."
          },
          "status" => %{
            "type" => "array",
            "items" => %{
              "type" => "string",
              "enum" => ["todo", "in_progress", "blocked", "done", "cancelled"]
            },
            "description" => "Optional status filter for recent mode."
          },
          "assignee" => %{
            "type" => "string",
            "description" => "Optional assignee filter for recent mode."
          },
          "sort_by" => %{
            "type" => "string",
            "enum" => ["updated_at", "created_at", "due_date"],
            "description" => "Sort for recent mode. Default: updated_at (most recent first)."
          },
          "limit" => %{
            "type" => "integer",
            "description" => "Max results for recent mode. Default: 20. Max: 200."
          },
          "include_history" => %{
            "type" => "boolean",
            "description" => "Include change history. Default: false."
          },
          "include_comments" => %{
            "type" => "boolean",
            "description" => "Include comments. Default: true."
          },
          "include_subtasks" => %{
            "type" => "boolean",
            "description" => "Include subtasks. Default: true."
          }
        },
        "required" => []
      }
    }
  end

  @impl true
  def domain, do: :tasks

  @impl true
  def isolation_level, do: :none
end
```

### 3.3 Skill Count Summary

| Skill | Operation | When the LLM Uses It |
|-------|-----------|---------------------|
| `tasks.create` | Create | "Add a task to...", "Remind me to...", "Track this..." |
| `tasks.search` | Read (list) | "What's on my plate?", "Show overdue tasks", "What's Bob working on?" |
| `tasks.get` | Read (detail / explicit set) | "Tell me about task X", "Get these task IDs", "Show recent tasks" |
| `tasks.update` | Update | "Mark X as done", "Reassign to...", "Push the deadline to..." |
| `tasks.delete` | Archive | "Delete task X", "Cancel the...", "No longer needed" |

Five tools. Focused and clear. The LLM selects based on intent.

`tasks.get` supports three retrieval modes under one CLI command:
- **Single**: `tasks.get --task_id <uuid>`
- **Plural**: `tasks.get --task_ids <uuid1,uuid2,uuid3>`
- **Recent**: `tasks.get --recent true --limit 25 [--status todo,in_progress]`

Use `tasks.search` for semantic discovery (text search, tags, overdue logic). Use `tasks.get` when the target task(s) are already known, or when the user asks for a recent slice.

---

## 4. Search and Filter Design

### 4.1 Approach: Structured Parameters (Not Natural Language Parsing)

The LLM translates natural language into structured filter parameters. The skill does NOT receive raw natural language for parsing — the LLM does that translation as part of CLI command generation.

**Example user request**: "Show me Bob's overdue high-priority tasks tagged with Q1"

**LLM generates CLI command**:
```cmd
tasks.search --assignee "Bob" --overdue true --priority high --tags Q1
```

**Runtime parser normalizes flags into structured filters**:
```elixir
%{
  "assignee" => "Bob",
  "overdue" => true,
  "priority" => ["high"],
  "tags" => ["Q1"]
}
```

This approach is reliable because:
- CLI command contracts and `--help` descriptions guide argument shape
- Skill schemas still provide clear enum values and types for parser validation
- No ambiguity in filter semantics — each parameter has a defined meaning
- No custom NLP parsing layer to build or maintain

### 4.2 Query Composition (Ecto)

The search skill builds an Ecto query dynamically from the provided parameters.

```elixir
defmodule Assistant.Skills.Tasks.Search do
  def build_query(filters) do
    from(t in Task, where: is_nil(t.archived_at))
    |> maybe_filter_status(filters)
    |> maybe_filter_assignee(filters)
    |> maybe_filter_priority(filters)
    |> maybe_filter_tags(filters)
    |> maybe_filter_due_before(filters)
    |> maybe_filter_due_after(filters)
    |> maybe_filter_overdue(filters)
    |> maybe_filter_text(filters)
    |> apply_sort(filters)
    |> apply_limit(filters)
  end

  defp maybe_filter_tags(query, %{tags: tags}) when is_list(tags) and tags != [] do
    where(query, [t], fragment("? @> ?", t.tags, ^tags))
  end
  defp maybe_filter_tags(query, _), do: query

  defp maybe_filter_text(query, %{query: text}) when is_binary(text) and text != "" do
    where(query, [t], fragment(
      "? @@ plainto_tsquery('english', ?)",
      t.search_vector, ^text
    ))
  end
  defp maybe_filter_text(query, _), do: query

  defp maybe_filter_overdue(query, %{overdue: true}) do
    today = Date.utc_today()
    query
    |> where([t], t.due_date < ^today)
    |> where([t], t.status not in ["done", "cancelled"])
  end
  defp maybe_filter_overdue(query, _), do: query
end
```

### 4.3 Default Behavior

When the LLM calls `tasks.search` with no filters (e.g., user says "what are my tasks?"), the defaults provide a sensible view:
- **Status**: `['todo', 'in_progress', 'blocked']` (active tasks only)
- **Assignee**: Current user (inferred from conversation context)
- **Sort**: `due_date` ascending (most urgent first)
- **Limit**: 20

The skill executor injects the current user's identity from the SkillContext, so the LLM doesn't need to specify assignee for "my tasks" queries.

---

## 5. Assignee Resolution

### 5.1 Problem

The LLM will pass assignee names as free text (e.g., "Bob", "Sarah Chen", "me"). This must resolve to a `users.id` UUID.

### 5.2 Approach: Fuzzy Name Resolution

```elixir
defmodule Assistant.Tasks.AssigneeResolver do
  @doc """
  Resolves a name string to a user_id.
  Handles: exact match, partial match, "me"/"myself", display name.
  Returns {:ok, user_id} | {:error, :not_found} | {:error, :ambiguous, [matches]}
  """
  def resolve(name_string, %SkillContext{} = ctx) do
    cond do
      name_string in ["me", "myself", "I"] ->
        {:ok, ctx.user_id}

      true ->
        case fuzzy_match_user(name_string) do
          [single] -> {:ok, single.id}
          [] -> {:error, :not_found}
          multiple -> {:error, :ambiguous, multiple}
        end
    end
  end

  defp fuzzy_match_user(name) do
    # Case-insensitive match on display_name
    from(u in User,
      where: fragment("? ILIKE ?", u.display_name, ^"%#{name}%")
    )
    |> Repo.all()
  end
end
```

**Ambiguity handling**: If multiple users match, the skill returns an error result asking the LLM to clarify: "Multiple users match 'Sam': Sam Chen, Sam Williams. Which one?"

The LLM then asks the user to clarify, and retries with the specific name.

---

## 6. Memory Integration

### 6.1 Task Completion -> Long-Term Memory

When a task transitions to `done`, the system should optionally create a memory entry. Not all completed tasks are worth remembering — only those with substance.

**Criteria for memory extraction**:
- Task has a description (not just a title)
- Task has comments or history entries
- Task was discussed in conversations (linked via `created_via_conversation_id`)

**Memory entry format**:
```
Completed task: "{title}"
Assigned to: {assignee}
Completed: {completed_at}
Key details: {description summary}
Outcome: {final comment or status change context}
```

This is stored as a memory entry with:
- `category`: `'task_completion'`
- `importance`: Based on priority (critical=0.9, high=0.7, medium=0.5, low=0.3)
- Tags set to `["task_completion", domain_tag]` for structured filtering
- Searchable via PostgreSQL FTS (tsvector generated from the combined text)

### 6.2 Contextual Task References

When the memory context builder assembles context for an LLM call, it should check for relevant open tasks. Two integration points:

**A. Active task injection (per conversation turn)**:
Before each LLM call, check if the user has overdue or high-priority tasks. Include a brief summary in the system prompt context:

```
You have awareness of the user's tasks:
- 2 overdue tasks (highest priority: "Finalize Q1 report" due 2026-02-15)
- 5 active tasks total
The user can ask about their tasks at any time.
```

This is lightweight (2-3 lines) and keeps the LLM aware without consuming excessive context tokens.

**B. Full-text retrieval on relevant topics**:
When the user mentions something that relates to an existing task (e.g., "I need to work on the Q1 report"), the memory system's full-text search should surface the relevant task entry. Tasks' `search_vector` and any memory entries from task completions are both searchable via PostgreSQL FTS + tags + structured filters.

### 6.3 Conversation-Task Linking

Every task created during a conversation records `created_via_conversation_id`. Every update made during a conversation is logged in `task_history` with `changed_via_conversation_id`. This bidirectional link allows:
- From task: "Show me the conversation where this task was created"
- From conversation: "What tasks were created during this discussion?"

---

## 7. Notification Hooks

### 7.1 Task-Triggered Notifications

Task state changes should trigger notifications through the existing notification system (`Assistant.Notifications.Router`).

| Trigger | Notification | Channel | Timing |
|---------|-------------|---------|--------|
| Task overdue | "Task '{title}' is overdue (was due {due_date})" | Assignee's preferred channel | Checked by scheduler, once per day |
| Task assigned to someone | "{creator} assigned you: '{title}'" | Assignee's preferred channel | Immediate |
| Task marked done | "Task '{title}' completed by {user}" | Task creator (if different from completer) | Immediate |
| Task blocked | "Task '{title}' is now blocked" | Assignee's preferred channel | Immediate |
| Due date approaching | "Task '{title}' is due in {N} days" | Assignee's preferred channel | 1 day before (configurable) |

### 7.2 Implementation via Oban

Task notifications are Oban jobs triggered by the task skill's `execute/2` function after a successful state change.

```elixir
# After task update
defp maybe_notify(task, old_status, new_status, context) do
  cond do
    new_status == "done" and old_status != "done" ->
      %{type: "task_completed", task_id: task.id, completed_by: context.user_id}
      |> Assistant.Notifications.TaskNotificationWorker.new()
      |> Oban.insert()

    task.assignee_id != context.user_id and task.assignee_id_changed? ->
      %{type: "task_assigned", task_id: task.id, assigned_by: context.user_id}
      |> Assistant.Notifications.TaskNotificationWorker.new()
      |> Oban.insert()

    true -> :ok
  end
end
```

### 7.3 Overdue Check via Quantum

A Quantum cron job runs daily to check for overdue tasks and approaching deadlines.

```elixir
# In Quantum scheduler config
config :assistant, Assistant.Scheduler.Cron,
  jobs: [
    # Check for overdue tasks daily at 9:00 AM
    {"0 9 * * *", {Assistant.Scheduler.Jobs, :check_overdue_tasks, []}},
    # Check for approaching deadlines daily at 9:00 AM
    {"0 9 * * *", {Assistant.Scheduler.Jobs, :check_approaching_deadlines, []}}
  ]
```

---

## 8. Recurring Tasks

### 8.1 Model

Recurring tasks use a template pattern:
- A task with `recurrence_rule` is a **template** (it is never directly worked on)
- The scheduler generates concrete **instances** from templates
- Each instance links back via `recurrence_source_id`

### 8.2 Recurrence Rule Format

```json
{
  "frequency": "weekly",
  "interval": 1,
  "day_of_week": "monday",
  "end_date": "2026-06-30",
  "generate_ahead_days": 7
}
```

Supported frequencies: `daily`, `weekly`, `monthly`, `yearly`.

### 8.3 Generation Logic

A Quantum cron job generates upcoming task instances:

```elixir
def generate_recurring_tasks do
  templates = Repo.all(
    from t in Task,
      where: not is_nil(t.recurrence_rule),
      where: is_nil(t.archived_at)
  )

  for template <- templates do
    next_dates = calculate_next_dates(template.recurrence_rule, template)
    for date <- next_dates do
      unless instance_exists?(template.id, date) do
        create_instance(template, date)
      end
    end
  end
end
```

Instances are generated `generate_ahead_days` into the future (default: 7 days). This ensures there's always a concrete upcoming task visible.

---

## 9. Multi-User Design

### 9.1 Assignment Model

Tasks have a single `assignee_id`. The assistant resolves names to user IDs via the AssigneeResolver (Section 5).

### 9.2 Visibility Rules

For a small team tool, all tasks are visible to all users. There is no access control beyond what the assistant naturally provides (it answers the asking user's questions about tasks).

If privacy becomes needed later, add an `visibility` column (`public`, `assignee_only`, `creator_and_assignee`).

### 9.3 Cross-User Scenarios

| Scenario | Assistant Behavior |
|----------|--------------------|
| "Assign this to Bob" | Resolves "Bob" -> user_id, sets assignee_id, notifies Bob |
| "What's Bob working on?" | `tasks.search --assignee "Bob" --status in_progress` |
| "What's overdue for the team?" | `tasks.search --overdue true` |
| "Reassign all of Sarah's tasks to me" | Multiple `tasks.update` calls (LLM iterates results from search) |

---

## 10. Integration with Existing Architecture

### 10.1 Skill Registry

The five task skills register in `Assistant.Skills.Registry` like any other domain:

```elixir
# In Registry startup
register_skills([
  Assistant.Skills.Tasks.Create,
  Assistant.Skills.Tasks.Search,
  Assistant.Skills.Tasks.Get,
  Assistant.Skills.Tasks.Update,
  Assistant.Skills.Tasks.Delete
])
```

They appear in skill discovery and CLI help output alongside email, calendar, drive, etc.

### 10.2 Orchestrator

No changes to the orchestration engine. Task skills are invoked through the same agent loop as any other skill. The orchestrator's circuit breakers and iteration limits apply identically.

### 10.3 Notification System

Task notifications go through `Assistant.Notifications.Router` using the existing severity and dedup infrastructure. A new Oban worker (`TaskNotificationWorker`) handles task-specific notification formatting.

### 10.4 Scheduler

Two new Quantum cron jobs:
- `check_overdue_tasks` — daily scan for overdue tasks, triggers notifications
- `generate_recurring_tasks` — daily generation of upcoming recurring task instances

Both dispatch work via Oban for reliability.

### 10.5 Memory System

Two integration points:
- Task completions optionally feed into `memories` table (Section 6.1)
- Active task summaries injected into LLM context per conversation turn (Section 6.2)

---

## 11. Schema Summary

### New Tables

| Table | Purpose | Row Estimate (small team) |
|-------|---------|--------------------------|
| `tasks` | Core task records | Hundreds to low thousands |
| `task_dependencies` | Blocking relationships | Tens |
| `task_comments` | Discussion on tasks | Hundreds |
| `task_history` | Audit trail of all changes | Thousands |

### New Modules

| Module | Type | Purpose |
|--------|------|---------|
| `Assistant.Skills.Tasks.Create` | Skill | Create task |
| `Assistant.Skills.Tasks.Search` | Skill | Search/filter tasks |
| `Assistant.Skills.Tasks.Get` | Skill | Get task details |
| `Assistant.Skills.Tasks.Update` | Skill | Update task |
| `Assistant.Skills.Tasks.Delete` | Skill | Archive task |
| `Assistant.Tasks.AssigneeResolver` | Service | Resolve name strings to user IDs |
| `Assistant.Tasks.RecurrenceGenerator` | Service | Generate recurring task instances |
| `Assistant.Notifications.TaskNotificationWorker` | Oban Worker | Format and dispatch task notifications |
| `Assistant.Schemas.Task` | Ecto Schema | Task schema |
| `Assistant.Schemas.TaskDependency` | Ecto Schema | Dependency schema |
| `Assistant.Schemas.TaskComment` | Ecto Schema | Comment schema |
| `Assistant.Schemas.TaskHistory` | Ecto Schema | History schema |

### Ecto Schemas (Elixir)

```elixir
defmodule Assistant.Schemas.Task do
  use Ecto.Schema

  schema "tasks" do
    field :title, :string
    field :description, :string
    field :status, :string, default: "todo"
    field :priority, :string, default: "medium"
    field :tags, {:array, :string}, default: []
    field :due_date, :date
    field :due_time, :utc_datetime
    field :started_at, :utc_datetime
    field :completed_at, :utc_datetime
    field :archived_at, :utc_datetime
    field :archive_reason, :string
    field :recurrence_rule, :map
    field :metadata, :map, default: %{}

    belongs_to :assignee, Assistant.Schemas.User
    belongs_to :creator, Assistant.Schemas.User
    belongs_to :created_via_conversation, Assistant.Schemas.Conversation
    belongs_to :parent_task, Assistant.Schemas.Task
    belongs_to :recurrence_source, Assistant.Schemas.Task

    has_many :subtasks, Assistant.Schemas.Task, foreign_key: :parent_task_id
    has_many :comments, Assistant.Schemas.TaskComment
    has_many :history, Assistant.Schemas.TaskHistory

    many_to_many :blocking_tasks, Assistant.Schemas.Task,
      join_through: "task_dependencies",
      join_keys: [blocked_task_id: :id, blocking_task_id: :id]

    many_to_many :blocked_tasks, Assistant.Schemas.Task,
      join_through: "task_dependencies",
      join_keys: [blocking_task_id: :id, blocked_task_id: :id]

    timestamps()
  end
end
```

---

## 12. Open Questions

1. **Task-to-external linking**: Should tasks link to HubSpot deals, Drive files, or calendar events via the `metadata` JSONB field? Or should there be explicit join tables? Recommend JSONB for now — explicit joins only if query patterns demand it.

2. **Batch operations**: Should there be a `tasks.batch_update` skill for bulk operations (e.g., "mark all Q1 tasks as done")? Or should the LLM iterate through search results and call `tasks.update` per item? Recommend starting without batch — the agent loop handles iteration naturally. Add batch later if token cost becomes an issue.

3. **Task templates beyond recurrence**: Should users be able to create non-recurring task templates (e.g., "New client onboarding checklist" that creates 5 subtasks)? This is a natural extension but adds complexity. Defer to Phase 2.

4. **Notification preferences**: Should users be able to configure which task notifications they receive (e.g., "don't notify me about low-priority task assignments")? Ties into the broader notification_rules system. Design supports it via the existing `notification_rules` table.
