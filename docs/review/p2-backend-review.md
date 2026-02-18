# Phase 2 Backend Review

**Reviewer**: pact-backend-coder
**Date**: 2026-02-18
**Scope**: Memory backend, compaction, task management, skill handlers, context auto-assembly

---

## Blocking Issues

### B1. `context_builder.ex:105` -- Bare pattern match on `{:ok, entries}` crashes on error

```elixir
defp fetch_relevant_memories(user_id, query, limit) do
  {:ok, entries} = Search.search_memories(user_id, query: query, limit: limit)
  entries
rescue
  error -> ...
end
```

`Search.search_memories/2` always returns `{:ok, list}` today, but this bare match will raise `MatchError` if the underlying Repo call ever returns `{:error, _}` (e.g. DB timeout). The `rescue` clause catches it, but using exceptions for normal error flow is an Elixir anti-pattern and produces misleading stack traces.

**Fix**: Use `case` and handle `{:error, _}` explicitly:
```elixir
case Search.search_memories(user_id, query: query, limit: limit) do
  {:ok, entries} -> entries
  {:error, _} -> []
end
```

### B2. `context_builder.ex:205` -- `truncate_to_budget/2` mixes `byte_size` with `String.slice` character count

```elixir
defp truncate_to_budget(text, max_chars) when byte_size(text) <= max_chars, do: text

defp truncate_to_budget(text, max_chars) do
  limit = max_chars - 20
  String.slice(text, 0, limit) <> "\n...[truncated]"
end
```

The guard uses `byte_size/1` (bytes), but the truncation uses `String.slice/3` (grapheme count). For multi-byte UTF-8 content (accented characters, emoji, CJK), `byte_size` will be larger than the character count, meaning the guard may pass when the character count is well over budget, or the truncation may produce a result with more bytes than `max_chars`. This is a data correctness issue since the budget is described in chars.

**Fix**: Use `String.length(text)` in the guard instead of `byte_size(text)`, or switch the budget semantics to bytes consistently. Since the comment says "~4 chars/token", character count is the intended unit.

### B3. `compaction.ex:92-115` -- Incremental compaction re-summarizes already-summarized messages

When `summary_version > 0` (incremental run), `fetch_new_messages/2` fetches the N most recent messages by `inserted_at DESC` then reverses them. However, there is no mechanism to track which messages were already covered by the previous summary. If the conversation has 200 messages and the batch size is 100, the second compaction re-fetches the last 100 messages -- which includes many messages already summarized in the first run. Over time, summaries will drift toward recency bias and may lose early-conversation context.

The code acknowledges this with a comment ("A more precise approach would track the last-compacted message ID"), but the current behavior can cause data loss in the summary. This is the core compaction algorithm, so getting it right matters.

**Fix**: Add a `last_compacted_message_id` field to the `conversations` table (or reuse `updated_at` from the summary bump) and filter `where: m.inserted_at > ^last_compaction_at` for incremental runs.

---

## Minor Issues

### M1. `queries.ex:574-583` -- Short ID generation has a TOCTOU race window

`generate_short_id/0` queries `MAX(short_id)` then builds the next value. Between the SELECT and the INSERT, another process can insert the same short_id. The retry loop (`@max_short_id_retries = 3`) mitigates this by catching the unique constraint violation and retrying, so it won't crash, but under high concurrency the retries could all collide.

**Impact**: Low risk -- the retry loop handles it. For future hardening, consider a DB sequence or `SELECT ... FOR UPDATE` approach if task creation volume increases.

### M2. `queries.ex:598-601` -- `String.to_existing_atom/1` in `normalize_opts` can raise on unknown keys

```elixir
defp normalize_opts(opts) when is_map(opts) do
  Enum.map(opts, fn
    {k, v} when is_binary(k) -> {String.to_existing_atom(k), v}
    {k, v} -> {k, v}
  end)
end
```

If a caller passes a map with an unexpected string key that hasn't been compiled as an atom, this raises `ArgumentError`. Since `search_tasks` and `list_tasks` accept keyword opts, and the function is designed to normalize maps into keyword-like lists, this is a crash waiting to happen with external input.

**Fix**: Use `String.to_atom/1` with a whitelist, or filter to known keys only.

### M3. `search.ex:329-337` -- `touch_accessed_at` runs synchronously on every search

The `touch_accessed_at/1` helper fires a bulk `UPDATE ... SET accessed_at` on every search call. This adds a write to every read path, which could become a bottleneck under load. The comment says "Runs as a bulk update to avoid N+1 queries" but it still blocks the search response.

**Impact**: Low at current scale. If search becomes latency-sensitive, consider moving this to an async Task or a batch updater.

### M4. `agent.ex:497` -- Message list grows unboundedly during LLM loop

```elixir
new_messages = context.messages ++ [assistant_msg | tool_msgs]
```

Each loop iteration appends to the messages list. The `max_tool_calls` budget (default 15) limits iterations, but each iteration can add multiple messages (1 assistant + N tool results). With 15 iterations of 3 tool calls each, the list could reach ~60+ messages. This is probably fine for the memory agent's focused missions, but there is no explicit guard against context window overflow.

**Impact**: Low -- the tool call budget acts as an implicit limit. Worth monitoring.

### M5. `agent.ex:90-94` -- `Application.compile_env` makes LLM client non-swappable at runtime

```elixir
@llm_client Application.compile_env(:assistant, :llm_client, Assistant.Integrations.OpenRouter)
```

This is a compile-time constant. Tests can override it via config, but runtime injection (e.g., for A/B testing models) is not possible. This is the same pattern used in `turn_classifier.ex:39-43`. Consistent across the codebase, so not a blocking issue, but worth noting for future flexibility.

### M6. `compact_conversation.ex:86-93` -- `parse_int` returns `nil` for invalid input, passed as Oban arg

```elixir
args = Map.put(args, :token_budget, parse_int(budget))
```

If `budget` is a non-numeric string like "abc", `parse_int` returns `nil`, and `nil` gets stored in the Oban job args. The `CompactionWorker.build_opts/1` handles `nil` gracefully (skips the key), so this won't crash, but it silently discards the user's intent to set a budget.

**Impact**: Minor UX issue. Could log a warning when a non-parseable value is provided.

### M7. `extract_entities.ex:87-96` -- Race condition fallback re-queries after insert failure

```elixir
case Repo.insert(MemoryEntity.changeset(%MemoryEntity{}, attrs)) do
  {:ok, entity} -> ...
  {:error, _changeset} ->
    case find_entity(user_id, name, entity_type) do
      nil -> %{name: name, entity_type: entity_type, error: "insert_failed"}
      entity -> %{name: entity.name, ...}
    end
end
```

Good pattern for handling race conditions. The `nil` fallback path (insert failed AND re-query found nothing) is a defensive edge case. Currently returns an `error: "insert_failed"` map entry that gets included in the results but is not surfaced as a failure to the caller. This is acceptable.

### M8. `query_entity_graph.ex:76-142` -- `visited` set not shared across sibling branches

The `traverse_relations` function passes `visited` through the recursion, but when traversing multiple next-hop entities in `Enum.flat_map`, each sibling branch gets the same `visited` set from the parent. This means entity A's relations could appear in entity B's deeper traversal if they share neighbors. For `@max_depth = 3` this produces duplicate relation entries in the output, not incorrect data.

**Impact**: Low -- produces duplicate entries at depth > 1 but no data corruption. Could deduplicate results before returning.

### M9. `tasks/update.ex:104-136` -- `apply_tag_changes` fetches the task again, creating a double-read

When `--add-tag` or `--remove-tag` flags are present, the handler calls `Queries.get_task(task_id)` to read current tags, then passes the modified attrs to `Queries.update_task(task_id, attrs)` which reads the task again. This is two SELECT queries for the same row.

**Impact**: Minor performance cost. Could be optimized by passing the fetched task into `update_task` or by combining the read.

### M10. `skills/memory/search.ex:59` -- Single-clause `case` without error handling

```elixir
case MemorySearch.search_memories(context.user_id, opts) do
  {:ok, entries} -> ...
end
```

If `search_memories` ever returns `{:error, _}`, this will raise `CaseClauseError`. Unlike `context_builder.ex` which has a rescue, this handler has no fallback.

**Fix**: Add an `{:error, reason}` clause that returns a `%Result{status: :error, ...}`.

---

## Future Considerations

### F1. Memory search does not use vector embeddings

FTS via `plainto_tsquery` is a solid Phase 2 approach. The moduledoc notes "deferred to Phase 3" for pgvector. The `Search` module is well-structured for later augmentation -- the `maybe_fts` chain can be extended with a `maybe_vector_search` clause.

### F2. Compaction model resolution is synchronous

`resolve_compaction_model/0` calls `ConfigLoader.model_for(:compaction)` on every compaction. If the config system becomes slow or the ETS table is temporarily unavailable, this blocks the compaction pipeline. Not an issue now since ETS reads are nanosecond-fast.

### F3. No rate limiting on memory writes from TurnClassifier

Every turn that classifies as `save_facts` triggers a memory agent dispatch. If a chatty conversation produces many turns in quick succession, the memory agent queues up missions but can only process them sequentially. The 60-second compaction cooldown in `ContextMonitor` does not apply to `TurnClassifier` save operations.

### F4. Entity graph traversal could become expensive

`query_entity_graph.ex` supports depth-3 traversal with no limit on the number of relations per hop. A densely connected entity could produce a combinatorial explosion. The `@max_depth = 3` cap mitigates this, but adding a `max_relations_per_hop` limit would be safer.

### F5. Task search does not scope by user_id

`search_tasks/1` and `list_tasks/1` in `queries.ex` accept an optional `:assignee_id` filter but do not require it. In a multi-user deployment, a search without `:assignee_id` returns tasks across all users. The skill handler (`tasks/search.ex`) does not inject `context.user_id` as a filter.

---

## Summary

The Phase 2 backend implementation is well-structured with clean module boundaries, consistent error tuple conventions, and good defensive patterns (retry loops for short_id, race condition handling in entity upserts, sentinel security gating). The code follows Elixir conventions (with chains, pattern matching on function heads, Ecto.Multi for atomicity).

**Three blocking items** need attention: the bare match in context_builder (B1), the byte_size/String.slice mismatch (B2), and the compaction algorithm's lack of message tracking (B3). The minor items are low-risk improvements that can be addressed incrementally.

**Strongest areas**: Store module's CRUD consistency, CompactionWorker's Oban integration (correct unique/retry config), SkillExecutor's search-first enforcement pattern, and the entity graph skill handlers.

**Weakest area**: The compaction algorithm's incremental message selection (B3), which is the most architecturally significant issue in this review.
