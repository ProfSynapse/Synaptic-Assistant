# Phase 2 Architect Review

**Reviewer**: pact-architect
**PR**: #7 (Phase 2 -- Multi-Agent Memory)
**Date**: 2026-02-18
**Verdict**: **Approve with minor fixes**

---

## Summary

Phase 2 adds the memory subsystem (Store, Search, Compaction, ContextBuilder, MemoryAgent), background triggers (ContextMonitor, TurnClassifier), task management (TaskManager.Queries), 12 skill handlers (7 memory, 5 task), a compaction Oban worker, and context auto-assembly integration into the orchestrator.

Overall, the architecture is well-structured. Modules have clear single responsibilities, the dependency graph flows downward (skill handlers -> domain modules -> Repo), and OTP patterns are used correctly. The search-first enforcement via SkillExecutor is a thoughtful correctness gate. The compaction fold algorithm is sound. I found no blocking issues that require changes before merge -- only minor improvements and future work.

---

## Blocking Issues

None.

---

## Minor Issues (Should fix but not blocking)

### M1. ContextBuilder `truncate_to_budget` uses `byte_size` guard but `String.slice` for truncation

**File**: `lib/assistant/memory/context_builder.ex:205-211`

The guard clause uses `byte_size(text)` which counts bytes, but multi-byte UTF-8 characters (e.g., emoji, CJK) make `byte_size` > `String.length`. This means:
- Strings that fit in characters could get falsely routed to the truncation branch (minor inefficiency, not a bug)
- The truncation itself uses `String.slice` (grapheme-based) which is correct

**Recommendation**: Change the guard to `String.length(text) <= max_chars` for consistency with the truncation logic. Or, if performance matters, accept the current approximation and add a comment explaining the intentional byte-size shortcut.

**Severity**: Low -- the current behavior is conservative (over-truncates slightly), not a data integrity issue.

### M2. Compaction `fetch_new_messages` for incremental fold fetches by recency, not by compaction boundary

**File**: `lib/assistant/memory/compaction.ex:92-115`

For incremental compaction (`summary_version > 0`), the code fetches the most recent N messages and reverses them. The comment acknowledges this is a heuristic. The problem is that if a conversation has 200 messages and the compaction batch size is 100, incremental compaction will always re-summarize the same last 100 messages, never advancing the boundary.

**Recommendation**: Track `last_compacted_message_id` on the Conversation schema (or derive it from the summary version + message count at compaction time). This allows the incremental fold to correctly pick up only messages added since the last compaction.

**Severity**: Medium -- produces correct but redundant summaries. Wastes LLM tokens on already-summarized content. Not a data integrity issue. Address before high-volume usage.

### M3. MemoryAgent hardcoded for `dev-user` in application.ex

**File**: `lib/assistant/application.ex:40`

```elixir
{Assistant.Memory.Agent, user_id: "dev-user"},
```

This starts a single MemoryAgent for a hardcoded user ID. In production, MemoryAgents should be started dynamically per-user via the DynamicSupervisor, not in the static supervision tree.

**Recommendation**: Replace with a DynamicSupervisor child spec for Memory.Agent, and start/stop agents dynamically when sessions begin/end. For dev purposes, keep the hardcoded startup behind a `Mix.env() == :dev` guard or move it to `dev.exs` config. This is fine for Phase 2 scope but must change before multi-user support.

**Severity**: Medium -- blocks multi-user deployment. Acceptable for single-user dev phase.

### M4. `Compaction.compact/2` `with` chain does not distinguish LLM vs prompt errors in its return

**File**: `lib/assistant/memory/compaction.ex:68-80`

The `with` chain propagates errors upward, but `render_system_prompt` converts `:not_found` into a fallback (good), while `call_llm` wraps errors in `{:llm_call_failed, reason}`. The `build_user_prompt` always returns `{:ok, _}` so it never fails. This is fine, but the caller (CompactionWorker) only pattern-matches on a few specific error atoms.

**Recommendation**: Document the full error taxonomy in the `@spec` or `@doc` for `compact/2` so that callers know which error tuples to expect. Minor.

### M5. ContextMonitor unbounded `last_compaction_at` map

**File**: `lib/assistant/memory/context_monitor.ex:50`

The `last_compaction_at` map grows with one entry per conversation ID and is never cleaned up. For a long-running system, this is a slow memory leak.

**Recommendation**: Add a periodic cleanup (e.g., remove entries older than 10 minutes since they are only used for 60-second cooldown) or use `:ets` with TTL. Low priority -- won't matter for months at typical conversation volumes.

### M6. TurnClassifier `@classification_prompt` uses `{{template}}` syntax but substitution is manual `String.replace`

**File**: `lib/assistant/memory/turn_classifier.ex:46-55, 97-100`

The prompt template uses `{{user_message}}` placeholders replaced via `String.replace/3`. This is fine functionally, but inconsistent with the rest of the codebase which uses EEx via PromptLoader for prompt templates.

**Recommendation**: Extract to a YAML prompt file in `config/prompts/` and use PromptLoader for consistency. Not a correctness issue.

### M7. TaskManager.Queries `normalize_opts/1` swallows atom conversion errors silently

**File**: `lib/assistant/task_manager/queries.ex:597-601`

`String.to_existing_atom/1` will raise `ArgumentError` if the string key doesn't correspond to an existing atom. This is good for security (no atom table exhaustion) but means that if an LLM passes an unexpected key string, it will crash the query.

**Recommendation**: Wrap in a rescue or use a whitelist approach: define allowed keys and filter/map only recognized ones. The current crash behavior is arguably correct (fail-fast on bad input), so this is a judgment call.

### M8. Duplicate `parse_tags`, `parse_int`, `parse_importance` helpers across skill handlers

**Files**: Multiple handlers in `lib/assistant/skills/memory/` and `lib/assistant/skills/tasks/`

The `parse_tags/1`, `parse_int/1`, `parse_float/1`, `parse_importance/1`, and `format_changeset_errors/1` functions are duplicated across 5+ handlers.

**Recommendation**: Extract into a shared `Assistant.Skills.ParamHelpers` module. Not urgent -- handlers are small and the duplication is boilerplate.

---

## Architectural Analysis

### Separation of Concerns -- Good

| Module | Responsibility | Clean? |
|--------|---------------|--------|
| `Memory.Store` | CRUD persistence layer | Yes -- single responsibility, no business logic |
| `Memory.Search` | FTS + entity graph retrieval | Yes -- pure query module, no writes |
| `Memory.Compaction` | Incremental summary fold | Yes -- orchestrates Store + LLM, no state |
| `Memory.ContextBuilder` | Context assembly for LLM injection | Yes -- read-only, graceful degradation |
| `Memory.Agent` | GenServer for LLM-driven memory operations | Yes -- clear lifecycle, delegated skill execution |
| `Memory.SkillExecutor` | Search-first enforcement wrapper | Yes -- single gate concern |
| `Memory.ContextMonitor` | PubSub threshold watcher | Yes -- stateless aside from cooldown tracking |
| `Memory.TurnClassifier` | LLM-based turn classification | Yes -- async via TaskSupervisor |
| `TaskManager.Queries` | Task CRUD + search + dependencies | Yes -- comprehensive, well-organized |
| `Orchestrator.Context` | Cache-optimized context assembly | Yes -- clean integration with ContextBuilder |

### Interface Contracts -- Good

All public functions have consistent `{:ok, result} | {:error, reason}` return types with `@spec` annotations. The `Handler` behaviour is correctly implemented by all 12 handlers. Function signatures are well-documented.

### OTP Patterns -- Correct

**GenServer usage (MemoryAgent):**
- Proper `start_link/1` with `:via` tuple registration in `SubAgent.Registry`
- Mission dispatched via `handle_continue` to avoid blocking init
- LLM loop runs in `Task.async` to avoid blocking the GenServer
- `handle_info` correctly handles both task completion and DOWN messages
- The `receive` block in the task process for pause/resume is acceptable since it runs in the async task, not the GenServer process

**GenServer usage (ContextMonitor, TurnClassifier):**
- Correct PubSub subscription in `init`
- TurnClassifier correctly delegates LLM calls to `Task.Supervisor` to avoid blocking

**Supervision tree:**
- Correct ordering: Config > Repo > PubSub > Oban > Skills > Registries > Agent > Monitors > Endpoint
- `one_for_one` strategy is appropriate since components are independent

### Dependency Graph -- Clean

```
Skill Handlers (memory.*, tasks.*)
    |
    v
Memory.Store / Memory.Search / TaskManager.Queries
    |
    v
Repo (Ecto)

Memory.Agent --> Memory.SkillExecutor --> Skills.Executor --> Handler
                                      |
                                      v
                              Memory.Store / Search

ContextMonitor ---(PubSub)---> Memory.Agent
TurnClassifier ---(PubSub)---> Memory.Agent

Orchestrator.Context --> Memory.ContextBuilder --> Memory.Store + Search + TaskManager.Queries
```

No circular dependencies. Data flows downward. PubSub provides loose coupling for background triggers.

### Compaction Architecture -- Sound

The incremental fold pattern (`summary(n) = LLM(summary(n-1), new_messages)`) is a well-known approach for managing growing conversation context. The dual trigger mechanism (threshold-based via ContextMonitor + topic-change via TurnClassifier) provides good coverage. The Oban worker provides reliable async execution with deduplication and retry.

The main architectural risk is the "fetch recent N" heuristic for incremental compaction (M2 above), which should be replaced with proper boundary tracking before high-volume usage.

### Search-First Enforcement -- Well-Designed

The SkillExecutor pattern is clean:
- Read skills set a session flag
- Write skills check the flag
- Session resets per dispatch mission
- Rejection returns a specific error atom that the Nudger converts to corrective LLM guidance

This prevents the common failure mode of LLM agents writing duplicate or conflicting memories without first checking what exists.

### Entity Graph -- Appropriate for Phase 2

The entity graph (entities + temporally-valid relations) is well-modeled. The `close_relation` pattern (set `valid_to`, never delete) preserves full history. Multi-hop traversal with cycle detection in `QueryEntityGraph` is bounded by `@max_depth 3`.

---

## Future Improvements (GitHub Issues)

### F1. Dynamic MemoryAgent lifecycle management
Replace hardcoded `dev-user` startup with dynamic start/stop via DynamicSupervisor tied to session lifecycle. Required for multi-user.

### F2. Compaction boundary tracking
Add `last_compacted_message_id` to Conversation schema so incremental compaction only processes new messages. See M2.

### F3. ContextMonitor cleanup of cooldown map
Periodic pruning of the `last_compaction_at` entries to prevent slow memory growth. See M5.

### F4. Shared parameter parsing helpers
Extract common `parse_tags`, `parse_int`, `parse_float`, `format_changeset_errors` into `Skills.ParamHelpers`. See M8.

### F5. PromptLoader integration for TurnClassifier
Move classification prompt to `config/prompts/` for consistency with other components. See M6.

---

## Verdict

**Approve with minor fixes.**

The architecture is well-structured with clear separation of concerns, consistent interfaces, correct OTP patterns, and a sound compaction algorithm. The 12 skill handlers all correctly implement the Handler behaviour. The search-first enforcement is a valuable correctness gate. Context auto-assembly integrates cleanly with the orchestrator.

M2 (compaction boundary tracking) and M3 (hardcoded user ID) are the most impactful items but are acceptable for Phase 2 scope. None of the minor issues threaten data integrity or correctness in the current single-user dev context.
