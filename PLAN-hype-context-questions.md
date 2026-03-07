# HyPE Memory Retrieval + Context Questions Implementation Plan

## Overview

Two complementary features that improve memory retrieval:
1. **HyPE (write path)**: Generate hypothetical search queries when saving memories, stored in a `search_queries` column and folded into the tsvector for better FTS matching.
2. **Context Questions (read path)**: Required `context_questions` array on `dispatch_agent` — each question runs as an FTS query pre-LLM, with results injected into the sub-agent system prompt. Plus: default read-only memory access for all sub-agents.

---

## Step 1: Migration — Add `search_queries` column

**File**: `priv/repo/migrations/20260307120000_add_search_queries_to_memory_entries.exs`

**What**:
- Add `search_queries` column (`{:array, :text}`, default `[]`) to `memory_entries`
- Drop the existing generated `search_text` tsvector column
- Re-create `search_text` as a generated tsvector that combines `content` AND `search_queries`:
  ```sql
  ALTER TABLE memory_entries ADD COLUMN search_text tsvector GENERATED ALWAYS AS (
    to_tsvector('english', coalesce(content, '')) ||
    to_tsvector('english', coalesce(array_to_string(search_queries, ' '), ''))
  ) STORED
  ```
- Re-create the GIN index on `search_text`

**Down migration**: Drop `search_queries`, revert `search_text` to content-only formula.

---

## Step 2: Schema — Add `search_queries` to MemoryEntry

**File**: `lib/assistant/schemas/memory_entry.ex`

**What**:
- Add `field :search_queries, {:array, :string}, default: []` to the schema
- Add `:search_queries` to `@optional_fields`
- No validation needed — it's an array of strings, any content is fine

---

## Step 3: Write path — Generate queries on memory save

**File**: `lib/assistant/skills/memory/save.ex`

**What**:
- In `build_attrs/2`, pass through `flags["search_queries"]` if present
- The memory agent LLM is already generating the save call — we just need to update the skill definition to accept `search_queries` and the prompt to instruct it to generate them

**File**: `priv/skills/memory/save_memory.md`

**What**:
- Add `search_queries` parameter (type: array, items: string, required: false)
- Description: "3-5 hypothetical questions this memory answers. Used for retrieval matching."
- Update usage notes to explain the pattern

**File**: `priv/config/prompts/memory_agent.yaml` (or wherever the memory agent system prompt lives)

**What**:
- Add instruction to the memory agent: when calling `memory.save_memory`, always include a `search_queries` array with 3-5 natural-language questions this memory would answer
- Example: for content "Alice is a senior backend engineer specializing in distributed systems", generate queries like "Who has distributed systems experience?", "What does Alice Chen do?", "Who could lead a microservices project?"

---

## Step 4: Compact conversation — Also generate queries

**File**: `lib/assistant/skills/memory/compact_conversation.ex`

**What**:
- When compaction creates memory entries, also generate `search_queries` for each
- This may need an LLM call per compacted memory, or we can batch them
- If the compact skill already uses an LLM to summarize, extend that prompt to also produce queries

---

## Step 5: `dispatch_agent` tool — Add required `context_questions`

**File**: `lib/assistant/orchestrator/tools/dispatch_agent.ex`

**What** in `tool_definition/0`:
- Add `context_questions` to `properties`:
  ```elixir
  "context_questions" => %{
    "type" => "array",
    "items" => %{"type" => "string"},
    "description" =>
      "Questions the agent needs answered before starting. Each question " <>
      "is searched against the memory system and matching memories are " <>
      "pre-loaded into the agent's context. Always include 2-5 questions " <>
      "about what the agent needs to know to complete its mission."
  }
  ```
- Add `"context_questions"` to the `"required"` list (alongside agent_id, mission, skills)

**What** in `validate_params/1`:
- Extract `context_questions` from params, validate it's a list
- Add to the validated map: `context_questions: params["context_questions"] || []`

**What** in `build_dispatch_params/2`:
- Include `context_questions: validated.context_questions`

---

## Step 6: Memory prefetch module

**File**: `lib/assistant/memory/prefetch.ex` (NEW)

**What**:
```elixir
defmodule Assistant.Memory.Prefetch do
  @moduledoc """
  Resolves context_questions against the memory system before sub-agent
  execution. Each question runs as an FTS query; results are deduplicated
  and formatted for system prompt injection.
  """

  alias Assistant.Memory.Search

  @default_per_question_limit 3
  @max_total_results 10

  @doc """
  Runs each question as an FTS search against the user's memories.
  Returns a formatted string suitable for system prompt injection,
  or "" if no results found.
  """
  @spec resolve(binary(), [String.t()], keyword()) :: String.t()
  def resolve(user_id, questions, opts \\ [])
  def resolve(_user_id, [], _opts), do: ""

  def resolve(user_id, questions, opts) do
    per_q_limit = Keyword.get(opts, :per_question_limit, @default_per_question_limit)

    results =
      questions
      |> Enum.flat_map(fn question ->
        case Search.search_memories(user_id, query: question, limit: per_q_limit) do
          {:ok, entries} ->
            Enum.map(entries, fn e -> {question, e} end)
          _ ->
            []
        end
      end)
      |> deduplicate_by_entry_id()
      |> Enum.take(@max_total_results)

    format_prefetch_context(results)
  end
end
```

Key design decisions:
- Each question → separate FTS query (not one combined query) so results stay grouped by question
- Deduplicate by `entry.id` — same memory matching multiple questions appears once
- Cap total results at 10 to stay within token budget
- Returns formatted string or "" (no nil — consistent with existing context patterns)

Format output as:
```
## Pre-fetched Memory Context

> What skills does Project Neptune require?
- Project Neptune is a Kubernetes infrastructure overhaul... [tags: project, kubernetes]

> Who has Kubernetes experience?
- Eva Schmidt is a DevOps lead specializing in Kubernetes... [tags: person, kubernetes]
```

---

## Step 7: Sub-agent context injection

**File**: `lib/assistant/orchestrator/sub_agent.ex`

**What** in `build_context_with_files/3` (around line 1131):
- After building system_prompt, before constructing messages:
  ```elixir
  prefetch_context = Prefetch.resolve(
    dispatch_params.user_id,
    dispatch_params[:context_questions] || []
  )
  ```
- Inject into `system_content` after the existing system prompt and context_payload prefix:
  ```elixir
  system_content =
    [context_payload.prompt_prefix, system_prompt, prefetch_context]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n\n")
  ```

---

## Step 8: Default read-only memory skills for all sub-agents

**File**: `lib/assistant/orchestrator/sub_agent.ex`

**What** in `effective_skills/1` (around line 1304):
- Define module attribute for default read skills:
  ```elixir
  @default_memory_read_skills ["memory.search_memories", "memory.query_entity_graph"]
  ```
- Always inject them:
  ```elixir
  defp effective_skills(dispatch_params) do
    base_skills = dispatch_params.skills || []

    skills = Enum.uniq(base_skills ++ @default_memory_read_skills)

    if peer_query_available?(dispatch_params) do
      Enum.uniq(skills ++ [@peer_query_skill])
    else
      skills
    end
  end
  ```

This means every sub-agent can search memories on its own if the pre-fetched context isn't sufficient, but it can never write/delete memories unless explicitly granted `memory.save_memory`, `memory.extract_entities`, etc.

---

## Step 9: Orchestrator prompt update

**File**: `priv/config/prompts/orchestrator.yaml`

**What** — update the dispatch_agent section (around line 80-85):
- Add `context_questions` to the bulleted list of required fields:
  ```
  - context_questions: 2-5 questions the agent needs answered before starting.
    Think: "what does this agent need to know to complete its mission?" Each
    question is searched against memory and results pre-loaded into the agent's
    context. Even if you think memory is empty, always provide questions —
    the system handles zero-result cases gracefully.
  ```
- Add example to the multi-agent patterns section:
  ```
  - "Email John an update on Project Atlas" → 1 agent: emailer with
    context_questions: ["What is the current status of Project Atlas?",
    "What recent decisions were made about Atlas?", "What is John's email?"]
  ```

---

## Step 10: Orchestrator pre-fetch (user message → memory)

**File**: `lib/assistant/orchestrator/context.ex`

**What** in `auto_build_context/2` (around line 234):
- Extract the last user message from `loop_state` (it stores messages)
- Pass it as `:query` to `ContextBuilder.build_context`:
  ```elixir
  defp auto_build_context(loop_state, opts) do
    conversation_id = loop_state[:conversation_id]
    user_id = loop_state[:user_id]
    user_query = extract_last_user_message(loop_state)

    if user_id do
      merged_opts = Keyword.put_new(opts, :query, user_query)
      case ContextBuilder.build_context(conversation_id, user_id, merged_opts) do
        ...
      end
    end
  end

  defp extract_last_user_message(loop_state) do
    loop_state[:messages]
    |> List.wrap()
    |> Enum.reverse()
    |> Enum.find_value(fn
      %{role: "user", content: content} when is_binary(content) -> content
      _ -> nil
    end)
  end
  ```

This gives the orchestrator itself memory context based on the user's actual message (not just the stale conversation summary).

---

## Step 11: File-to-memory caching pipeline

When a file is read (via `context_files` in a dispatch or via the `files.read` skill), we
create a memory entry that summarizes the file and generates `search_queries` for it. This
turns every file read into a permanent, searchable memory — subsequent questions about that
file's content get answered from memory without re-reading the file.

### Step 11a: File memory module

**File**: `lib/assistant/memory/file_cache.ex` (NEW)

**What**:
```elixir
defmodule Assistant.Memory.FileCache do
  @moduledoc """
  Creates memory entries from file reads. Summarizes file content via LLM,
  generates search_queries, and persists as a memory entry with
  source_type "system" and category "file_cache".

  Deduplicates by checking for an existing memory with the same file path
  tag before creating a new one. If found, updates content instead.
  """

  alias Assistant.Memory.{Search, Store}
  alias Assistant.Integrations.OpenRouter

  @max_content_for_summary 12_000

  @doc """
  Caches a file's content as a memory entry with generated search_queries.

  Runs an LLM call to:
  1. Summarize the file content (~200 words)
  2. Generate 5-8 questions this file's content answers

  Returns {:ok, entry} or {:error, reason}.
  """
  @spec cache_file(binary(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def cache_file(user_id, file_path, content, opts \\ [])
end
```

Key design:
- Tag with `["file_cache", "file:#{file_path}"]` for dedup lookup
- Before creating, search for existing memory with tag `"file:#{file_path}"`
  - If found and content hash matches → skip (already cached)
  - If found and content hash differs → update (file changed)
  - If not found → create new
- LLM prompt asks for JSON: `{"summary": "...", "search_queries": [...]}`
- Store the content hash in metadata: `%{"file_path" => path, "content_hash" => hash}`
- source_type: `"system"`, category: `"file_cache"`, importance: `0.60`
- Truncate input to `@max_content_for_summary` chars before sending to LLM

### Step 11b: Hook into ContextFiles.load

**File**: `lib/assistant/orchestrator/context_files.ex`

**What**:
- After successfully loading a text file entry (in `classify_entry/4`, the `@text_formats` branch):
- Enqueue async file caching via an Oban worker (don't block the context load):
  ```elixir
  # In classify_entry, after adding to acc.texts:
  FileCacheWorker.new(%{
    user_id: opts[:user_id],
    file_path: entry.path,
    content: entry.contents
  }) |> Oban.insert()
  ```
- This is fire-and-forget — the sub-agent doesn't wait for the cache to be built

### Step 11c: FileCacheWorker (Oban)

**File**: `lib/assistant/memory/file_cache_worker.ex` (NEW)

**What**:
```elixir
defmodule Assistant.Memory.FileCacheWorker do
  use Oban.Worker,
    queue: :memory,
    max_attempts: 2,
    unique: [period: 300, keys: [:user_id, :file_path]]

  alias Assistant.Memory.FileCache

  @impl true
  def perform(%Oban.Job{args: %{"user_id" => user_id, "file_path" => path, "content" => content}}) do
    case FileCache.cache_file(user_id, path, content) do
      {:ok, _entry} -> :ok
      {:error, :already_cached} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
```

Key design:
- `unique: [period: 300, keys: [:user_id, :file_path]]` — same file for same user within 5 min is deduplicated at the Oban level
- `queue: :memory` — same queue as other memory operations
- `max_attempts: 2` — LLM call may fail, one retry is fine
- The content is passed in the job args (not re-read) so the worker is self-contained

### Step 11d: Note on files.read skill

**File**: `lib/assistant/skills/files/read.ex` — **NO CHANGE for now**

The `files.read` skill currently reads directly from the Drive API, bypassing the sync
layer. Drive files are already synced to local markdown/csv via the `SyncPollWorker` →
`FileSyncWorker` → `Converter` pipeline and stored encrypted in `synced_files`.

`context_files.ex` already reads from synced local copies (via `StateStore` +
`FileManager`), so the `FileCacheWorker` hook in Step 11b covers the primary file
reading path.

**Future work** (separate PR): Refactor `files.read` to read from synced local copies
instead of the Drive API. Once that's done, it would naturally go through `context_files`
and get the caching hook for free.

---

## Step 12: Tests

**File**: `test/assistant/memory/prefetch_test.exs` (NEW)
- Test `Prefetch.resolve/3` with workspace fixtures
- Verify deduplication across overlapping questions
- Verify empty questions → ""
- Verify per-question limit and total cap

**File**: `test/assistant/memory/file_cache_test.exs` (NEW)
- Test `FileCache.cache_file/4` creates memory with summary + search_queries
- Test dedup: same file path → no duplicate memory
- Test content hash change → updates existing memory
- Test truncation of large files before LLM call

**File**: `test/assistant/orchestrator/tools/dispatch_agent_test.exs` (EXISTING)
- Add test: `context_questions` is required — dispatch without it fails validation
- Add test: `context_questions: []` is valid (empty array OK)
- Add test: questions are passed through to dispatch_params

**File**: `test/assistant/orchestrator/sub_agent_test.exs` (EXISTING)
- Add test: pre-fetched context appears in system prompt
- Add test: default memory read skills are always present
- Add test: memory write skills NOT present unless explicitly granted

**File**: `test/integration/context_questions_llm_test.exs` (NEW)
- Integration test using MemoryFixtures: dispatch with context_questions, verify the sub-agent's system prompt contains relevant memories
- Test: "Email John about Atlas" with questions, verify Atlas memories in context

**File**: `test/assistant/skills/memory/save_test.exs` (EXISTING)
- Add test: `search_queries` are persisted when provided
- Add test: `search_queries` improve FTS matching (query matches a stored question but not the raw content)

---

## File Summary

| # | File | Action | Purpose |
|---|------|--------|---------|
| 1 | `priv/repo/migrations/20260307120000_add_search_queries_to_memory_entries.exs` | NEW | Add column, update tsvector |
| 2 | `lib/assistant/schemas/memory_entry.ex` | EDIT | Add field to schema |
| 3 | `lib/assistant/skills/memory/save.ex` | EDIT | Pass through search_queries |
| 4 | `priv/skills/memory/save_memory.md` | EDIT | Add parameter to skill def |
| 5 | `lib/assistant/memory/prefetch.ex` | NEW | Question → FTS → formatted context |
| 6 | `lib/assistant/orchestrator/tools/dispatch_agent.ex` | EDIT | Add required context_questions |
| 7 | `lib/assistant/orchestrator/sub_agent.ex` | EDIT | Inject prefetch + default read skills |
| 8 | `lib/assistant/orchestrator/context.ex` | EDIT | User message as FTS query |
| 9 | `priv/config/prompts/orchestrator.yaml` | EDIT | Document context_questions |
| 10 | `priv/config/prompts/sub_agent.yaml` | EDIT | Document pre-fetched context section |
| 11 | Memory agent prompt (TBD) | EDIT | Instruct search_queries generation |
| 12 | `lib/assistant/memory/file_cache.ex` | NEW | Summarize file → memory + search_queries |
| 13 | `lib/assistant/memory/file_cache_worker.ex` | NEW | Oban worker for async file caching |
| 14 | `lib/assistant/orchestrator/context_files.ex` | EDIT | Enqueue FileCacheWorker on file load |
| 15 | `lib/assistant/skills/files/read.ex` | SKIP | Future: refactor to read from synced copies |
| 16 | `test/assistant/memory/prefetch_test.exs` | NEW | Prefetch unit tests |
| 17 | `test/assistant/memory/file_cache_test.exs` | NEW | File cache unit tests |
| 18 | `test/integration/context_questions_llm_test.exs` | NEW | E2E integration test |
| 19 | Existing test files (3) | EDIT | Add coverage for new fields |

---

## Execution Order

The steps have some dependencies. Recommended build order:

1. **Steps 1-2** (migration + schema) — foundation, everything depends on this
2. **Steps 3-4** (save skill + compact) — write path, can test in isolation
3. **Step 6** (Prefetch module) — pure function, no dependencies beyond Search
4. **Steps 5, 7-8** (dispatch_agent + sub_agent + context.ex) — read path, depends on Prefetch
5. **Steps 9-10** (prompts) — can be done anytime
6. **Steps 11a-11d** (file cache pipeline) — independent track, depends on Steps 1-2
7. **Step 12** (tests) — after implementation is complete
