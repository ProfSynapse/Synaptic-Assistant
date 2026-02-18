# Phase 2 Gap Analysis: Multi-Agent Memory & Task Management

> Generated 2026-02-18 | Based on `feature/skills-first-assistant-foundation` branch (commit `a2f190f`)

## CRITICAL: Worktree Base Branch Issue

The Phase 2 worktree (`feature/phase-2-multi-agent-memory`) is based on `main` (`19849ad`), which contains **only documentation** -- no application code. Phase 1 source code lives exclusively on `origin/feature/skills-first-assistant-foundation` (`a2f190f`). The worktree must be rebased onto the Phase 1 branch before any coding begins.

**Fix**: `git rebase origin/feature/skills-first-assistant-foundation` in the worktree, or recreate the worktree from the correct base.

---

## Target 1: Sub-Agent DAG Scheduler

**File**: `lib/assistant/orchestrator/agent_scheduler.ex`
**Status**: FULLY DONE -- skip in coding phase

### What Exists

The AgentScheduler module is complete and production-ready:

- `plan_waves/1` -- Builds a dependency graph from `depends_on` fields, validates all dependencies exist, validates acyclicity via Kahn's algorithm, computes execution waves (topological layers)
- `execute/3` -- Takes dispatches map, Task.Supervisor pid, and an execute function. Runs waves sequentially; agents within each wave run in parallel via `Task.Supervisor.async_nolink/3`
- `wait_for_agents/4` -- Supports both `:wait_any` and `:wait_all` modes for the `get_agent_results` yield pattern
- Wave failure handling with transitive dependent skipping (BFS to find all dependents of failed agents)
- Proper error types: `{:error, :cycle_detected}`, `{:error, :unknown_dependency, dep}`
- Configurable timeouts: per-agent (`@default_agent_timeout` = 60s) and per-wave (`@max_wave_timeout` = 120s)

### No Gaps

This module is fully implemented. The Engine (`engine.ex`) already references and uses the AgentScheduler.

---

## Target 2: Memory Backend

**Files**: `lib/assistant/memory/store.ex`, `lib/assistant/memory/search.ex`, `lib/assistant/memory/context_builder.ex`
**Status**: MISSING ENTIRELY -- needs full implementation

### What Exists

**Schemas** (fully done):
- `Schemas.Conversation` -- has `summary`, `summary_version`, `summary_model` fields for continuous compaction
- `Schemas.Message` -- stores conversation messages with `role`, `content`, `tool_calls`, `token_count`
- `Schemas.MemoryEntry` -- stores long-term memories with `tags`, `category`, `importance`, `decay_factor`, `embedding_model`, `segment_start_message_id`/`segment_end_message_id` for progressive disclosure
- `Schemas.MemoryEntity` -- entity graph nodes (person, organization, project, concept, location) scoped per user
- `Schemas.MemoryEntityRelation` -- entity graph edges with temporal validity (`valid_from`/`valid_to`), `provenance`
- `Schemas.MemoryEntityMention` -- links entities to memory entries

**Database tables** (fully done via migrations):
- `memory_entries` table with FTS `search_text` tsvector column (auto-generated from `content || tags`)
- `memory_entities` table with unique constraint on `(user_id, name, entity_type)`
- `memory_entity_relations` table with temporal validity
- GIN indexes on `search_text` tsvector columns

**Supporting infrastructure** (done):
- `Memory.Agent` GenServer -- dispatches missions but currently calls skill stubs (no real DB backend)
- `Memory.SkillExecutor` -- search-first enforcement logic is complete, delegates to `Skills.Executor`
- `Memory.ContextMonitor` -- triggers compaction missions via PubSub when token utilization crosses threshold
- `Memory.TurnClassifier` -- classifies turns and dispatches save/extract missions to MemoryAgent
- `Orchestrator.Context` -- builds cache-friendly LLM context, has placeholder for `memory_context` and `task_summary` opts

### What's Missing

1. **`lib/assistant/memory/store.ex`** -- Conversation persistence layer
   - CRUD operations for conversations and messages via Ecto
   - `create_conversation/1`, `get_conversation/1`, `append_message/2`
   - `update_summary/3` -- atomic update of `summary`, `summary_version`, `summary_model`
   - `list_messages/2` -- paginated message retrieval with offset/limit
   - `get_messages_in_range/3` -- for compaction (by message ID range or index range)

2. **`lib/assistant/memory/search.ex`** -- Hybrid retrieval (FTS + tags + structured filters)
   - `search_memories/2` -- PostgreSQL FTS query on `memory_entries.search_text`
   - Tag filtering (`tags @> ARRAY[...]`)
   - Category filtering
   - User scoping (always filter by `user_id`)
   - Importance/decay weighting for ranking
   - `accessed_at` update on retrieval (for decay tracking)
   - Entity graph queries: search by entity name, traverse relations
   - **Future**: pgvector similarity search (embedding column exists but `embedding_model` field only; actual vector column not yet in migration -- may need a migration addition for `embedding vector(1536)`)

3. **`lib/assistant/memory/context_builder.ex`** -- Assembles LLM context from history + memory entries
   - `build_context/2` -- given a conversation_id and user_id, assembles:
     - Recent conversation summary (from `conversations.summary`)
     - Relevant memory entries (via search.ex, keyed to current topic)
     - Active tasks summary (via task_manager queries -- depends on Target 4)
   - Token budget management: fit assembled context within budget
   - This module is called by `Orchestrator.Context.build/3` (which currently takes `memory_context` as a pre-built string opt)

### Migration Gap

The `memory_entries` table exists but lacks an actual `embedding` vector column. The schema has `embedding_model` (string) but no vector field. If pgvector hybrid search is Phase 2 scope, a new migration is needed:
```sql
ALTER TABLE memory_entries ADD COLUMN embedding vector(1536);
CREATE INDEX ON memory_entries USING ivfflat (embedding vector_cosine_ops);
```

---

## Target 3: Continuous Compaction

**Files**: `lib/assistant/memory/compaction.ex`, `lib/assistant/scheduler/workers/compaction_worker.ex`
**Status**: MISSING ENTIRELY -- needs full implementation

### What Exists

**Trigger infrastructure** (done):
- `Memory.ContextMonitor` -- subscribes to `"memory:token_usage"` PubSub, dispatches `compact_conversation` mission to MemoryAgent when utilization crosses threshold (with 60s cooldown dedup)
- `Memory.TurnClassifier` -- classifies turns, dispatches `:compact_conversation` on topic change detection
- `Memory.Agent` -- accepts `{:mission, :compact_conversation, params}` cast and builds mission text instructing the LLM to perform compaction

**Prompt** (done):
- `config/prompts/compaction.yaml` -- system prompt for compaction model with EEx `token_budget` and `current_date` variables

**Schema support** (done):
- `Schemas.Conversation` has `summary`, `summary_version`, `summary_model` fields
- `Schemas.MemoryEntry` has `segment_start_message_id`/`segment_end_message_id` for progressive disclosure

**Dependencies** (done):
- Oban dependency in `mix.exs` (`{:oban, "~> 2.18"}`)
- Quantum scheduler in `lib/assistant/scheduler.ex`

### What's Missing

1. **`lib/assistant/memory/compaction.ex`** -- Core compaction logic
   - `compact/2` -- Incremental summary fold: `summary(n) = LLM(summary(n-1), turn(n))`
   - Reads current `conversation.summary` + new messages since `summary_version`
   - Calls compaction-tier LLM model (cheap, fast) with `compaction.yaml` prompt
   - Atomically updates `conversation.summary`, increments `summary_version`, sets `summary_model`
   - Extracts memory entries from summarized content (or delegates to MemoryAgent)
   - Handles first compaction (no prior summary) vs. incremental compaction
   - **Depends on**: `memory/store.ex` (read messages, update summary)

2. **`lib/assistant/scheduler/workers/compaction_worker.ex`** -- Oban worker
   - Oban worker that wraps `compaction.ex` for reliable async execution
   - Unique job per conversation_id (prevent concurrent compaction of same conversation)
   - Retry policy: max 3 attempts with exponential backoff
   - Called by ContextMonitor/TurnClassifier instead of (or in addition to) direct MemoryAgent dispatch
   - **Note**: Currently ContextMonitor dispatches directly to MemoryAgent via GenServer cast. The Oban worker provides durability (survives process crashes, node restarts). Decision needed: replace direct cast with Oban enqueue, or keep both paths.

### Integration Point

The current flow is: ContextMonitor/TurnClassifier -> MemoryAgent (GenServer cast) -> LLM loop with compaction mission text. This is an "LLM-driven compaction" where the MemoryAgent's LLM decides how to compact by calling memory skills.

Phase 2 should add a **direct compaction path**: ContextMonitor -> CompactionWorker (Oban) -> `Compaction.compact/2` (direct Elixir function, no LLM loop). This is more reliable and cheaper than routing through an LLM agent for what is essentially a deterministic operation (read messages, call summarization model, write summary).

The LLM-driven path via MemoryAgent can remain for more complex compaction scenarios (entity extraction during compaction).

---

## Target 4: Task Management Backend

**Files**: `lib/assistant/task_manager/` (task.ex, dependency.ex, comment.ex, history.ex, queries.ex)
**Status**: PARTIALLY DONE (schemas + tables done, query layer missing)

### What Exists

**Schemas** (fully done):
- `Schemas.Task` -- comprehensive: `short_id`, `title`, `description`, `status` (todo/in_progress/blocked/done/cancelled), `priority` (critical/high/medium/low), `tags`, `due_date`, `due_time`, `started_at`, `completed_at`, `archived_at`, `archive_reason`, `recurrence_rule`, `metadata`. Associations: `assignee`, `creator`, `created_via_conversation`, `parent_task`, `recurrence_source`, `subtasks`, `comments`, `history`
- `Schemas.TaskDependency` -- `blocking_task_id`, `blocked_task_id` with self-dependency constraint
- `Schemas.TaskComment` -- `content`, `task_id`, `author_id` (null = assistant-authored), `source_conversation_id`
- `Schemas.TaskHistory` -- audit trail: `field_changed`, `old_value`, `new_value`, `task_id`, `changed_by_user_id`

**Database tables** (fully done):
- `tasks` table with `search_vector` tsvector column (auto-generated from `title || description || tags`), GIN index
- `task_dependencies` table with unique constraint on `(blocking_task_id, blocked_task_id)` and no-self-dependency check
- `task_comments` table
- `task_history` table

### What's Missing

The `lib/assistant/task_manager/` directory does not exist. Needed:

1. **`lib/assistant/task_manager/queries.ex`** -- The main query module
   - `create_task/1` -- insert with auto-generated `short_id` (e.g., "T-001"), validates changeset
   - `get_task/1` -- fetch by `id` or `short_id`, preload subtasks/comments/history
   - `update_task/2` -- update fields, auto-log changes to `task_history`
   - `delete_task/1` -- soft delete via `archived_at` + `archive_reason`
   - `search_tasks/1` -- FTS on `search_vector`, plus structured filters (`status`, `priority`, `assignee_id`, `tags`, `due_date` range)
   - `list_tasks/1` -- filtered listing with pagination, sorting
   - `add_dependency/2` -- insert TaskDependency, validate no cycles (similar logic to AgentScheduler)
   - `remove_dependency/2`
   - `add_comment/2` -- insert TaskComment
   - `list_comments/1` -- comments for a task
   - `get_history/1` -- audit trail for a task
   - `generate_short_id/0` -- next sequential short_id ("T-001", "T-002", etc.)
   - `check_blocked_status/1` -- given a task_id, check if all blocking dependencies are done; auto-transition from "blocked" if unblocked

2. **Short ID generation** -- The schema has `short_id` as a string field with a unique constraint, but no generation logic exists. Need a reliable atomic counter (DB sequence or max+1 query).

---

## Target 5: Task Skills

**Files**: `lib/assistant/skills/tasks/` (create.ex, search.ex, get.ex, update.ex, delete.ex)
**Status**: MISSING ENTIRELY -- needs full implementation

### What Exists

**Infrastructure** (done):
- `Skills.Handler` behaviour -- `execute(flags, context)` callback
- `Skills.Executor` -- Task.Supervisor-based execution with timeouts
- `Skills.Registry` -- skill registration and lookup
- `Skills.Result` struct -- standardized return type
- `Skills.Context` struct -- execution context with `conversation_id`, `user_id`, etc.

**Skill markdown files** (not yet created for tasks):
- Memory skills have `.md` files in `priv/skills/memory/` -- same pattern needed for `priv/skills/tasks/`

### What's Missing

1. **`lib/assistant/skills/tasks/create.ex`** -- `@behaviour Handler`
   - Parses CLI flags: `--title`, `--description`, `--priority`, `--due`, `--tags`, `--parent`
   - Calls `TaskManager.Queries.create_task/1`
   - Returns `Result` with created task summary

2. **`lib/assistant/skills/tasks/search.ex`** -- `@behaviour Handler`
   - Parses: `--query`, `--status`, `--priority`, `--assignee`, `--tags`, `--due-before`, `--due-after`
   - Calls `TaskManager.Queries.search_tasks/1`
   - Returns `Result` with formatted task list

3. **`lib/assistant/skills/tasks/get.ex`** -- `@behaviour Handler`
   - Parses: task ID or short_id as positional arg
   - Calls `TaskManager.Queries.get_task/1`
   - Returns `Result` with full task details (subtasks, comments, history)

4. **`lib/assistant/skills/tasks/update.ex`** -- `@behaviour Handler`
   - Parses: task ID + fields to update (`--status`, `--priority`, `--title`, `--description`, `--assign`, `--add-tag`, `--remove-tag`)
   - Calls `TaskManager.Queries.update_task/2`
   - Returns `Result` with updated task

5. **`lib/assistant/skills/tasks/delete.ex`** -- `@behaviour Handler`
   - Parses: task ID, `--reason`
   - Calls `TaskManager.Queries.delete_task/1` (soft delete)
   - Returns `Result` with confirmation

6. **`priv/skills/tasks/SKILL.md`** -- Domain index
7. **`priv/skills/tasks/create.md`** through **`delete.md`** -- Skill markdown definitions with CLI usage docs
8. **`priv/skills/tasks/list.md`** -- List tasks (distinct from search -- may want a simple list view)

### Dependency

Task skills depend on `TaskManager.Queries` (Target 4). Build Target 4 first.

---

## Target 6: Memory Skills (Elixir Modules)

**Files**: `lib/assistant/skills/memory/` (save.ex, search.ex, get.ex)
**Status**: MISSING ENTIRELY -- needs full implementation

### What Exists

**Agent-side skill definitions** (done -- separate concern):
- `priv/skills/memory/*.md` -- 6 skill markdown files used by the MemoryAgent's LLM to understand what tools are available
- These are "planning tools" for the agent -- they describe what each skill does in natural language

**Execution infrastructure** (done):
- `Skills.Handler` behaviour
- `Skills.Executor` + `Memory.SkillExecutor` (search-first enforcement wrapper)
- `Skills.Registry` -- loads skills from `.md` files but does NOT yet wire Elixir handler modules

**SkillExecutor stub behavior** (current):
- When `Memory.SkillExecutor` receives a skill with `handler = nil`, it returns a stub result: `%Result{status: :ok, content: "{\"result\": \"stub\", \"message\": \"Skill handler not yet implemented.\"}"}`
- This means the MemoryAgent's LLM loop runs, but actual DB operations are no-ops

### What's Missing

1. **`lib/assistant/skills/memory/save.ex`** -- `@behaviour Handler`
   - Accepts: `content`, `tags`, `category`, `importance`, `source_type`
   - Calls `Memory.Store` to insert a `MemoryEntry`
   - Returns `Result` with saved entry ID

2. **`lib/assistant/skills/memory/search.ex`** -- `@behaviour Handler`
   - Accepts: `query`, `tags`, `category`, `limit`
   - Calls `Memory.Search` for hybrid FTS + filters
   - Returns `Result` with matching entries (summaries)

3. **`lib/assistant/skills/memory/get.ex`** -- `@behaviour Handler`
   - Accepts: memory entry ID
   - Calls `Memory.Store` to fetch full entry + linked conversation segment
   - Returns `Result` with full entry and transcript segment

4. **Additional handlers needed** (to match existing `.md` skill definitions):
   - `lib/assistant/skills/memory/extract_entities.ex` -- Creates/updates entities and relations in the graph
   - `lib/assistant/skills/memory/close_relation.ex` -- Sets `valid_to` on a relation
   - `lib/assistant/skills/memory/query_entity_graph.ex` -- Traverses entity graph
   - `lib/assistant/skills/memory/compact_conversation.ex` -- Triggers compaction for a conversation

5. **Registry wiring** -- The `.md` files need a `handler` frontmatter field (or separate registration) to link markdown definitions to Elixir handler modules. Currently the registry loads skills from `.md` files but the `handler` field is not populated. Need to either:
   - Add `handler: Assistant.Skills.Memory.Save` to each `.md` frontmatter, OR
   - Create a separate registration mechanism in the Registry for built-in skills

### Dependency

Memory skills depend on `Memory.Store` and `Memory.Search` (Target 2). Build Target 2 first.

---

## Phase 1 Stubs That Phase 2 Must Flesh Out

| Stub | File | Current Behavior | Phase 2 Action |
|------|------|-----------------|----------------|
| **Sentinel** | `lib/assistant/orchestrator/sentinel.ex` | Always returns `{:ok, :approved}` with info log | Add LLM-based evaluation (cheap model) -- could be Phase 3, but the wiring is ready |
| **Memory skill handlers** | `Memory.SkillExecutor.do_execute/4` | Returns stub `%Result{}` when handler is `nil` | Wire real handler modules (Target 6) |
| **Context memory injection** | `Orchestrator.Context.build/3` | Takes `memory_context` as a pre-built string opt (empty by default) | Wire `context_builder.ex` to auto-populate from search (Target 2) |
| **Context task summary** | `Orchestrator.Context.build/3` | Takes `task_summary` as a pre-built string opt (empty by default) | Wire `TaskManager.Queries` to generate active task summary (Target 4) |

---

## Recommended Coding Order

Dependencies flow: **Schemas (done)** -> **Backend modules** -> **Skills** -> **Integration wiring**

### Wave 1 (No Dependencies -- Parallel)

1. **Memory Store** (`lib/assistant/memory/store.ex`) -- CRUD for conversations, messages, memory entries
2. **Task Manager Queries** (`lib/assistant/task_manager/queries.ex`) -- CRUD + search for tasks

These two have no cross-dependencies and can be built in parallel by separate coders.

### Wave 2 (Depends on Wave 1)

3. **Memory Search** (`lib/assistant/memory/search.ex`) -- FTS + filters on memory entries (depends on Store for test data setup)
4. **Compaction** (`lib/assistant/memory/compaction.ex`) -- Incremental summary fold (depends on Store for message retrieval + summary updates)
5. **CompactionWorker** (`lib/assistant/scheduler/workers/compaction_worker.ex`) -- Oban wrapper (depends on Compaction)

### Wave 3 (Depends on Wave 1 + Wave 2)

6. **Memory Skills** (`lib/assistant/skills/memory/*.ex`) -- All 7 handler modules (depends on Store + Search)
7. **Task Skills** (`lib/assistant/skills/tasks/*.ex`) -- All 5 handler modules + markdown definitions (depends on Queries)
8. **Task skill markdown files** (`priv/skills/tasks/*.md`) -- Domain index + per-skill docs

### Wave 4 (Integration -- Depends on All Above)

9. **Context Builder** (`lib/assistant/memory/context_builder.ex`) -- Assembles LLM context from memory + tasks (depends on Store, Search, Queries)
10. **Registry wiring** -- Link markdown skill definitions to Elixir handler modules
11. **Context.build integration** -- Wire context_builder into `Orchestrator.Context.build/3` to auto-populate `memory_context` and `task_summary`

### Optional / Can Be Deferred

- Sentinel LLM evaluation (Phase 3 candidate)
- pgvector embedding column + vector similarity search (Phase 3 candidate -- FTS is sufficient for Phase 2)
- Config.Watcher hot-reload (pending task #32 from Phase 1)

---

## Summary Table

| Target | Status | Effort | Dependencies |
|--------|--------|--------|--------------|
| 1. Sub-Agent DAG Scheduler | **DONE** | -- | -- |
| 2. Memory Backend (store + search + context_builder) | **Missing** | Large | Schemas (done) |
| 3. Continuous Compaction | **Missing** | Medium | Memory Store |
| 4. Task Manager Queries | **Missing** | Medium | Schemas (done) |
| 5. Task Skills | **Missing** | Medium | Task Manager Queries |
| 6. Memory Skills (Elixir modules) | **Missing** | Medium | Memory Store + Search |
