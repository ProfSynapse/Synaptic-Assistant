# Phase 2 PR #7 — Fix Verification Report

**Reviewer**: verify-reviewer (Backend Coder)
**Date**: 2026-02-18
**Scope**: Verify 10 blocking items from p2-backend-review.md and p2-security-review.md
**Commits**: 483a74f through a6d51f9

---

## Summary

| Item | Status | Category |
|------|--------|----------|
| B1   | **FAIL** | Backend |
| B2   | PASS   | Backend |
| B3   | PASS   | Backend |
| SEC-B1 | PASS | Security |
| SEC-B2 | PASS | Security |
| SEC-B3 | PASS | Security |
| SEC-B4 | PASS | Security |
| SEC-B5 | PASS | Security |
| T1   | PASS   | Test |
| T2   | PASS   | Test |

**Result**: 9/10 PASS, 1/10 FAIL

---

## Detailed Verification

### B1: `context_builder.ex` ~line 105 — bare pattern match on Search.search_memories

**Status**: FAIL

**Requirement**: The bare `{:ok, entries} = Search.search_memories(...)` should be replaced with a `case` expression handling `{:error, _}` by returning `[]`.

**Evidence** (lines 104-114):

```elixir
defp fetch_relevant_memories(user_id, query, limit) do
  {:ok, entries} = Search.search_memories(user_id, query: query, limit: limit)
  entries
rescue
  error ->
    Logger.debug("ContextBuilder: memory search failed",
      reason: Exception.message(error)
    )

    []
end
```

**Analysis**: The bare `{:ok, entries} = ...` pattern match is still present. If `Search.search_memories` returns `{:error, reason}`, this raises a `MatchError`, which is caught by the `rescue` block. While the `rescue` block does degrade gracefully (returns `[]`), the original review item specifically requested a `case` expression with an explicit `{:error, _}` clause. Using `rescue` to catch a `MatchError` from a deliberate pattern-match failure is an anti-pattern in Elixir — it obscures the intent and catches unrelated exceptions too. The `rescue` was pre-existing; no `case` was added.

**Verdict**: The intent (graceful degradation) is met via the rescue, but the specific fix (replacing bare match with `case`) was NOT applied. The bare `{:ok, entries} =` remains on line 105. This is a **FAIL** because the requested change was not made.

---

### B2: `context_builder.ex` ~line 205 — `truncate_to_budget` uses `byte_size` instead of `String.length`

**Status**: PASS

**Requirement**: The guard in `truncate_to_budget` should use `String.length(text)` (character count) instead of `byte_size(text)` (byte count), since multi-byte UTF-8 characters would cause incorrect truncation.

**Evidence** (lines 206-213):

```elixir
defp truncate_to_budget(text, max_chars) do
  if String.length(text) <= max_chars do
    text
  else
    # Leave room for the truncation indicator
    limit = max_chars - 20
    String.slice(text, 0, limit) <> "\n...[truncated]"
  end
end
```

**Analysis**: `String.length(text)` is used on line 207 and `String.slice(text, 0, limit)` on line 211. Both operate on Unicode grapheme clusters, which is correct for character-level budget tracking.

**Verdict**: PASS.

---

### B3: `compaction.ex` — incremental fetch uses `last_compacted_message_id` boundary tracking

**Status**: PASS

**Requirement**: For `summary_version > 0`, compaction should use `last_compacted_message_id` boundary tracking instead of just a recency heuristic. Also: `Conversation` schema should have the field, and a migration should exist.

**Evidence — `compaction.ex` lines 95-161**:

```elixir
defp fetch_new_messages(conversation, message_limit) do
  summary_version = conversation.summary_version || 0

  messages =
    cond do
      summary_version == 0 ->
        Store.list_messages(conversation.id, limit: message_limit, order: :asc)

      conversation.last_compacted_message_id != nil ->
        # Precise boundary: fetch messages inserted after the last compacted one
        fetch_messages_after(
          conversation.id,
          conversation.last_compacted_message_id,
          message_limit
        )

      true ->
        # Legacy fallback: no boundary marker, use recency heuristic
        Store.list_messages(conversation.id,
          limit: message_limit,
          order: :desc
        )
        |> Enum.reverse()
    end
  ...
end
```

The `fetch_messages_after/3` helper (lines 131-161) queries the boundary message's `inserted_at` timestamp, then fetches messages strictly after it using `m.inserted_at > ^boundary_at or (m.inserted_at == ^boundary_at and m.id != ^boundary_message_id)`. Includes a fallback to recency heuristic if the boundary message was deleted.

On compact success (line 80-83), `last_compacted_message_id` is stored:
```elixir
last_message = List.last(messages)
Store.update_summary(conversation_id, summary_text, model.id,
  last_compacted_message_id: last_message.id
)
```

**Evidence — Conversation schema** (`lib/assistant/schemas/conversation.ex` line 28):
```elixir
field :last_compacted_message_id, :binary_id
```
Also in `@optional_fields` on line 51.

**Evidence — Migration** (`priv/repo/migrations/20260218200000_add_last_compacted_message_id_to_conversations.exs`):
```elixir
alter table(:conversations) do
  add :last_compacted_message_id,
      references(:messages, type: :binary_id, on_delete: :nilify_all)
end
```

**Evidence — Store.update_summary** (`lib/assistant/memory/store.ex` line 262+):
```elixir
def update_summary(conversation_id, summary_text, model_name, opts \\ []) do
  last_compacted_id = Keyword.get(opts, :last_compacted_message_id)
  ...
  set_fields =
    if last_compacted_id do
      Keyword.put(set_fields, :last_compacted_message_id, last_compacted_id)
    else
      set_fields
    end
```

**Verdict**: PASS. Complete implementation: 3-way cond dispatch, boundary-aware query, legacy fallback, schema field, migration, and Store persistence.

---

### SEC-B1: `task_manager/queries.ex` — all CRUD functions require and filter by user_id

**Status**: PASS

**Requirement**: `get_task/2`, `update_task/3`, `delete_task/3` require user_id and scope by `creator_id`. `search_tasks` and `list_tasks` return `{:error, :user_id_required}` if user_id missing.

**Evidence — `get_task/2`** (lines 173-182):
```elixir
def get_task(id_or_short_id, user_id) do
  base_task_query(id_or_short_id)
  |> where([t], t.creator_id == ^user_id)
  |> preload([:subtasks, comments: :author, history: []])
  |> Repo.one()
  |> case do
    nil -> {:error, :not_found}
    task -> {:ok, task}
  end
end
```

**Evidence — `update_task/3`** (lines 229-240):
```elixir
def update_task(id, attrs, user_id) do
  case Repo.get(Task, id) do
    nil -> {:error, :not_found}
    %Task{creator_id: creator_id} when creator_id != user_id ->
      {:error, :unauthorized}
    task -> do_update_task(task, attrs)
  end
end
```

**Evidence — `delete_task/3`** (lines 321-328):
```elixir
def delete_task(id, opts, user_id) do
  reason = Keyword.get(opts, :archive_reason, "cancelled")
  update_task(id, %{archived_at: DateTime.utc_now(), archive_reason: reason}, user_id)
end
```
Delegates to `update_task/3` which has the ownership check.

**Evidence — `search_tasks/1`** (lines 356-387):
```elixir
def search_tasks(opts) do
  opts = normalize_opts(opts)
  user_id = opts[:user_id]

  unless user_id do
    {:error, :user_id_required}
  else
    ...
    from(t in Task, where: t.creator_id == ^user_id, ...)
    ...
  end
end
```
Typespec on line 355: `@spec search_tasks(keyword() | map()) :: {:error, :user_id_required} | [Task.t()]`

**Evidence — `list_tasks/1`** (lines 412-434):
```elixir
def list_tasks(opts \\ []) do
  opts = normalize_opts(opts)
  user_id = opts[:user_id]

  unless user_id do
    {:error, :user_id_required}
  else
    ...
    from(t in Task, where: t.creator_id == ^user_id)
    ...
  end
end
```
Typespec on line 411: `@spec list_tasks(keyword() | map()) :: {:error, :user_id_required} | [Task.t()]`

**Verdict**: PASS. All five functions enforce user scoping. The 1-arity and 2-arity versions (without user_id) remain for internal/system use as documented.

---

### SEC-B2: `skills/memory/get.ex` — verify entry.user_id == context.user_id after fetch

**Status**: PASS

**Requirement**: After fetching a memory entry, verify ownership before returning it. Return `{:error, :not_found}` equivalent if mismatch.

**Evidence** (lines 35-42):
```elixir
case Store.get_memory_entry(entry_id) do
  {:ok, entry} when entry.user_id != context.user_id ->
    {:ok,
     %Result{
       status: :error,
       content: "Memory entry not found: #{entry_id}"
     }}

  {:ok, entry} ->
    ...
```

**Analysis**: Uses a guard clause `when entry.user_id != context.user_id` on the `{:ok, entry}` match. If ownership doesn't match, returns a generic "not found" error (no information leakage). The legitimate ownership case falls through to the second `{:ok, entry}` clause.

**Verdict**: PASS.

---

### SEC-B3: `skills/memory/close_relation.ex` — verify entity ownership before closing

**Status**: PASS

**Requirement**: Before closing a relation, verify that the entity belongs to the requesting user (entity.user_id == context.user_id).

**Evidence** (lines 86-113):
```elixir
defp close_relation(relation_id, user_id) do
  now = DateTime.utc_now()

  case Repo.get(MemoryEntityRelation, relation_id) do
    nil -> {:error, :not_found}

    %{valid_to: valid_to} when not is_nil(valid_to) ->
      {:error, :already_closed}

    relation ->
      # Verify ownership: load the source entity and check user_id
      source_entity = Repo.get(Assistant.Schemas.MemoryEntity, relation.source_entity_id)

      if is_nil(source_entity) or source_entity.user_id != user_id do
        {:error, :not_found}
      else
        ...update_all...
      end
  end
end
```

**Analysis**: The `execute/2` function on line 41 passes `context.user_id` to `close_relation/2`. The function loads the source entity and checks `source_entity.user_id != user_id`. Returns `:not_found` on mismatch (no information leakage).

**Verdict**: PASS.

---

### SEC-B4: `skills/memory/compact_conversation.ex` — verify conversation ownership before enqueuing

**Status**: PASS

**Requirement**: Before enqueuing an Oban compaction job, verify `conv.user_id == context.user_id`.

**Evidence** (lines 44-87):
```elixir
with {:ok, conv} <- Store.get_conversation(conversation_id),
     true <- conv.user_id == context.user_id do
  args = build_args(conversation_id, flags)
  case CompactionWorker.new(args) |> Oban.insert() do
    ...
  end
else
  _not_owned_or_not_found ->
    {:ok,
     %Result{
       status: :error,
       content: "Conversation not found: #{conversation_id}"
     }}
end
```

**Analysis**: The `with` chain fetches the conversation and then checks `conv.user_id == context.user_id`. If either the fetch fails or ownership doesn't match, the `else` clause returns a generic "not found" error. Clean and correct.

**Verdict**: PASS.

---

### SEC-B5: `task_manager/queries.ex` `normalize_opts/1` — safe allowlist instead of `String.to_existing_atom`

**Status**: PASS

**Requirement**: Replace `String.to_existing_atom/1` with a safe allowlist approach to prevent atom exhaustion.

**Evidence** (lines 62-76, 705-719):
```elixir
# Whitelist of known option keys for normalize_opts/1.
# Unknown string keys are silently dropped to avoid atom exhaustion attacks.
@known_opt_keys %{
  "query" => :query,
  "status" => :status,
  "priority" => :priority,
  "assignee_id" => :assignee_id,
  "tags" => :tags,
  "due_before" => :due_before,
  "due_after" => :due_after,
  "include_archived" => :include_archived,
  "limit" => :limit,
  "offset" => :offset,
  "sort_by" => :sort_by,
  "sort_order" => :sort_order,
  "user_id" => :user_id
}

defp normalize_opts(opts) when is_map(opts) do
  opts
  |> Enum.flat_map(fn
    {k, v} when is_binary(k) ->
      case Map.get(@known_opt_keys, k) do
        nil -> []
        atom_key -> [{atom_key, v}]
      end

    {k, v} when is_atom(k) ->
      [{k, v}]
  end)
end

defp normalize_opts(opts) when is_list(opts), do: opts
```

**Analysis**: No use of `String.to_existing_atom` or `String.to_atom`. String keys are mapped through a compile-time constant `@known_opt_keys` allowlist. Unknown string keys are silently dropped (line: `nil -> []`). Atom keys pass through directly (safe since they're already atoms). This is the correct defense against atom table exhaustion.

**Verdict**: PASS.

---

### T1: `test/assistant/memory/agent_test.exs` — setup block starts Config.Loader

**Status**: PASS

**Requirement**: The setup block should start `Config.Loader` (same pattern as `context_monitor_test.exs`).

**Evidence** (lines 51, 234-280):
```elixir
setup do
  ...
  # Config.Loader (ETS-backed GenServer for model/limits config)
  ensure_config_loader_started()
  ...
end

defp ensure_config_loader_started do
  if :ets.whereis(:assistant_config) != :undefined do
    :ok
  else
    ...
    case Assistant.Config.Loader.start_link(path: config_path) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end
  end
end
```

**Analysis**: `ensure_config_loader_started()` is called in the `setup` block (line 51). It checks for the ETS table, creates a temp config YAML with models/http/limits sections, and starts `Config.Loader`. Idempotent with the `{:error, {:already_started, _}}` guard.

**Verdict**: PASS.

---

### T2: `test/assistant/memory/compaction_test.exs` — behavioral tests + compaction_worker_test.exs Oban fix

**Status**: PASS

**Requirement**: `compaction_test.exs` should have behavioral tests (not just `function_exported?` smoke tests). `compaction_worker_test.exs` should address the Oban `--no-start` issue.

**Evidence — `compaction_test.exs`** (lines 36-161):
Four behavioral `describe` blocks:
1. `"compact/2 with no new messages"` — Creates a conversation with zero messages, asserts `{:error, :no_new_messages}` (line 43)
2. `"compact/2 with non-existent conversation"` — Asserts `{:error, :not_found}` (line 54)
3. `"compact/2 first-run with messages"` — Creates conversation + 3 messages, calls `compact/2`, asserts it progresses past message fetching (fails at LLM, not at `:no_new_messages`) (lines 62-88)
4. `"compact/2 incremental with existing summary"` — Creates conversation with `summary_version: 1` and prior summary, adds new messages, verifies incremental path progresses (lines 95-125)
5. `"compact/2 with custom options"` — Verifies custom `token_budget` and `message_limit` don't crash (lines 131-150)
6. `"module API"` — The `function_exported?` check remains but is supplementary (lines 156-161)

Uses `Assistant.DataCase` with real DB fixtures (Repo.insert!), proper Config.Loader and PromptLoader setup.

**Evidence — `compaction_worker_test.exs`** (lines 1-69):
Uses `use ExUnit.Case, async: true` (not DataCase), avoids Oban runtime dependency. Tests:
1. `Code.ensure_loaded?` instead of directly calling Oban functions that require the app started
2. `function_exported?` for `perform/1`, `new/1`, `new/2`
3. `CompactionWorker.new/1` changeset validation (valid?, args, queue, max_attempts, unique config)
4. Optional params (token_budget, message_limit) in args

The test avoids the `--no-start` Oban issue by testing changeset creation only (no `Oban.insert/1` calls that require running Oban).

**Verdict**: PASS.

---

## Overall Assessment

**9 of 10 items verified as correctly fixed.** One item (B1) remains unfixed — the bare pattern match in `fetch_relevant_memories` still uses `{:ok, entries} = Search.search_memories(...)` with a `rescue` fallback instead of the requested `case` expression.

### Regression Check

No regressions observed in the reviewed files. The fixes are well-scoped and do not introduce new issues.

### Recommendation

Fix B1 before merge: replace the bare `{:ok, entries} =` pattern match on `context_builder.ex` line 105 with a proper `case` expression:

```elixir
defp fetch_relevant_memories(user_id, query, limit) do
  case Search.search_memories(user_id, query: query, limit: limit) do
    {:ok, entries} ->
      entries

    {:error, reason} ->
      Logger.debug("ContextBuilder: memory search failed",
        reason: inspect(reason)
      )
      []
  end
end
```

This removes the `rescue` block entirely, making error handling explicit and idiomatic.
