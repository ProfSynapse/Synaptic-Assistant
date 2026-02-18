# Architect Review: Phase 1 Foundation (PR #1)

**Reviewer**: pact-architect
**Date**: 2026-02-18
**Scope**: Design coherence, architectural patterns, component boundaries, interface contracts, separation of concerns

---

## Executive Summary

Phase 1 delivers a well-structured OTP application with clear component boundaries and a coherent skill-based orchestration architecture. The system follows Elixir/OTP idioms effectively: ETS for concurrent reads, GenServers for state coordination, Task.Supervisor for fault-isolated execution, and PubSub for decoupled event propagation. The supervision tree ordering is correct, the circuit breaker hierarchy provides four defense layers, and the skill system is extensible by design (add-a-YAML-file).

The architecture has **no blocking issues**. There are several minor findings and future-phase items worth tracking.

---

## 1. OTP Supervision Tree (application.ex)

**Verdict: Sound**

### Strengths
- Child ordering is dependency-correct: Config.Loader (ETS) -> PromptLoader (needs config) -> Repo/PubSub/Oban -> Skills -> Orchestrator registries -> MemoryAgent -> Background triggers -> Web endpoint
- `strategy: :one_for_one` is appropriate: children are independent enough that a crash in one should not cascade
- DynamicSupervisor for per-conversation Engines is the right choice for a variable population

### Findings

**[Minor] M-SUP-1: Hardcoded dev user for MemoryAgent**
`application.ex:40` starts MemoryAgent with `user_id: "dev-user"`. This is suitable for Phase 1 single-user development but will need to become dynamic (supervised per-user) when multi-user support arrives. The current approach is pragmatic and documented in the comment. No action needed now, but this is the most obvious multi-user scaling point.

**[Future] F-SUP-1: No restart strategy tuning**
All children use default restart intensities. For production, consider:
- Config.Loader: `permanent` with a bounded restart intensity (crash-on-repeated-failure is fine for config)
- MemoryAgent: May benefit from `transient` restart if it should only restart on abnormal exit
- Background triggers (ContextMonitor/TurnClassifier): Stateless enough for aggressive restart

**[Future] F-SUP-2: Config.Watcher not yet wired**
Task #32 is pending for hot-reload watcher. The plumbing (reload APIs on Config.Loader and PromptLoader, cast-based skill reload on Registry) is already in place — just needs the file-system watcher GenServer.

---

## 2. SubAgent GenServer State Machine (sub_agent.ex)

**Verdict: Well-designed OTP pattern**

### Strengths
- Clean four-state machine: `:running` -> `:awaiting_orchestrator` -> `:running` (resume) | `:completed` | `:failed`
- LLM loop runs in a linked Task (via `Task.async`), keeping the GenServer responsive for status queries and resume commands
- `handle_continue(:start_loop, ...)` correctly defers heavy work out of `init/1`
- Scope enforcement is dual-layer: LLM tool enum restriction + runtime validation in `execute_use_skill`
- Context budget check with per-file breakdown gives the orchestrator LLM actionable information to retry with fewer files

### Findings

**[Minor] M-SA-1: `receive` block in Task has no timeout**
`sub_agent.ex:501-523` — The `receive do {:resume, update} ->` block inside the LLM loop Task has no `after` clause. If the orchestrator never calls `resume/2`, this Task blocks indefinitely. The GenServer itself has no timeout either.

*Mitigation*: The parent Engine has a 120s timeout (`wait_for_completion`), and the GenServer process will be cleaned up if the Engine terminates. However, an explicit timeout in the receive (e.g., 300s with a `:failed` status) would be more defensive.

**[Minor] M-SA-2: `wait_for_completion` race on normal exit**
`sub_agent.ex:1047-1052` — When the GenServer exits `:normal`, `get_status/1` is called. But the GenServer has already stopped (`:stop, :normal` in `handle_info`), so `get_status` will almost always hit the `catch :exit, {:noproc, _}` path and fall through to `fetch_from_registry_or_default`, which returns a stub with zero tool calls. The actual result is lost.

*Impact*: The `execute/3` synchronous API loses the final result details. The result is still logged and the status was set before termination, but the caller gets a degraded response. Consider having the GenServer send its final state to a known location (e.g., ETS or the parent process) before stopping.

**[Minor] M-SA-3: Duplicated response parsing helpers**
`extract_function_name`, `extract_function_args`, `has_text_no_tools?`, `has_tool_calls?` are duplicated identically across SubAgent, MemoryAgent, and LoopRunner. This should be extracted to a shared module (e.g., `Assistant.LLM.ResponseParser`). Not a design issue but a DRY violation across ~60 lines.

---

## 3. MemoryAgent GenServer (memory/agent.ex)

**Verdict: Good separation of persistent-agent vs ephemeral-agent patterns**

### Strengths
- Persistent lifecycle (idle -> running -> idle) is distinct from SubAgent's one-shot lifecycle — correct modeling of the different agent types
- `handle_cast({:mission, ...})` for fire-and-forget dispatch from ContextMonitor/TurnClassifier is the right choice; these callers don't need to wait
- Busy-drop semantics (log and discard if already running) is pragmatic for background triggers
- Search-first enforcement via SkillExecutor is a clean separation of concern — the agent doesn't enforce this itself

### Findings

**[Minor] M-MA-1: Missions silently dropped when busy**
`agent.ex:313-323` — When a mission arrives while the agent is busy, it's logged and discarded. For high-value missions (e.g., `compact_conversation`), this could mean the compaction never happens if the agent is perpetually busy.

*Recommendation*: Consider a simple mission queue (max 3-5 items) so that the agent can process queued work after completing its current mission. Alternatively, track dropped missions as a metric for operational visibility.

**[Minor] M-MA-2: Same `receive` without timeout issue as SubAgent**
`agent.ex:507-521` — Same pattern as M-SA-1. The Task blocks indefinitely waiting for resume.

**[Minor] M-MA-3: Sentinel check is pattern-matched to always succeed**
`agent.ex:580` — `{:ok, :approved} = Sentinel.check(...)` will crash the process if Sentinel ever returns a rejection in Phase 2. Should use a `case` with proper handling of `{:ok, {:rejected, reason}}`.

---

## 4. Config.Loader + PromptLoader (config/ modules)

**Verdict: Correct ETS-backed pattern, well-structured**

### Strengths
- ETS with `read_concurrency: true` for high-throughput reads from the hot path (every LLM call)
- GenServer only coordinates writes (reload), reads bypass GenServer entirely — no bottleneck
- Config.Loader crashes on bad config at startup (fail-fast) but keeps old config on hot-reload failure (graceful degradation) — exactly right
- PromptLoader is resilient: missing directory = warning, not crash. Callers have hardcoded fallbacks
- Environment variable interpolation (`${VAR}`) supports deployment flexibility

### Findings

**[Minor] M-CFG-1: `String.to_atom/1` on YAML keys without sanitization**
`loader.ex:274` — `parse_defaults` calls `String.to_atom(key)` on arbitrary YAML string keys. If an attacker could modify config.yaml, they could create atoms at will (atom table is finite, ~1M entries). In practice, config.yaml is a local file, but this is a hardening item.

`prompt_loader.ex:194` — Same pattern for prompt file names.

**[Minor] M-CFG-2: PromptLoader uses `Code.eval_quoted` for template rendering**
`prompt_loader.ex:273` — EEx templates are compiled once and stored, then rendered via `Code.eval_quoted`. This is the standard EEx pattern and is safe when templates come from the local filesystem. Worth noting that if template sources ever become user-controllable, this becomes a code injection vector.

---

## 5. Skill System (skills/ modules)

**Verdict: Clean extensibility, well-defined contracts**

### Strengths
- Handler behaviour (`execute/2 -> {:ok, Result} | {:error, term}`) is minimal and correct
- SkillDefinition struct separates metadata (YAML frontmatter) from content (markdown body) — clean data model
- Registry uses ETS with derived indexes (skill_by_domain, domain_indexes) for O(1) lookup by name and efficient filtering by domain
- Executor uses `Task.Supervisor.async_nolink` — crash isolation is correct; a crashing skill never takes down the calling GenServer
- `yield + shutdown` pattern ensures timed-out tasks are properly cleaned up

### Findings

**[Minor] M-SK-1: `search/1` does a full table scan**
`registry.ex:99-108` — `list_all()` fetches all skills, then filters in Elixir. With the expected skill count (tens to low hundreds), this is fine. If skill count grows to thousands, consider an ETS `:match_object` or a secondary tag index.

**[Future] F-SK-1: No handler validation at registration time**
When a skill with `handler: "Assistant.Skills.Email.Send"` is loaded, the handler module is converted to an atom but not validated as a loaded module implementing the Handler behaviour. A misspelled handler name would only fail at execution time. Consider a compile-time or load-time check.

---

## 6. Orchestrator Engine (engine.ex + loop_runner.ex + context.ex)

**Verdict: Strong separation of concerns; Engine = state, LoopRunner = pure logic**

### Strengths
- Engine GenServer owns state; LoopRunner is pure functions (stateless, testable) — excellent decomposition
- Context module handles cache-friendly message assembly with proper TTL breakpoints (1h for system prompt, 5min for context block)
- Usage-based context trimming (using actual `prompt_tokens` from API response as baseline, estimating only new messages) is a smart hybrid approach — more accurate than pure estimation
- The `{:text, ...} | {:tool_calls, ...} | {:wait, ...} | {:error, ...}` return protocol between LoopRunner and Engine is clean and exhaustive
- Per-conversation Task.Supervisor (`max_children: 10`) bounds concurrent sub-agents

### Findings

**[Minor] M-ENG-1: `send_message` call timeout is 120s**
`engine.ex:102` — The `GenServer.call` timeout is 120 seconds, which is long but may be needed for multi-agent orchestration turns. If the call times out, the Engine GenServer keeps running with partial state. The caller gets `{:error, :timeout}` but the Engine may still be mid-loop. Consider whether the Engine should detect that its caller has timed out and clean up.

**[Minor] M-ENG-2: Level 4 circuit breaker (per-conversation) not checked in the main loop**
The Engine creates `conversation_state: CircuitBreaker.new_conversation_state()` in init but never calls `CircuitBreaker.check_conversation/2` during the loop. Only levels 1-3 are actively enforced. The `check_all/4` function exists in CircuitBreaker but isn't used. This means the per-conversation sliding window rate limit is defined but not enforced.

**[Minor] M-ENG-3: Agent DAG execution blocks the GenServer call**
When `dispatch_agent` tool calls are processed, the Engine calls `AgentScheduler.execute` which spawns tasks and waits for all waves to complete. During this time, the `handle_call` for `send_message` is blocked. This is acceptable for Phase 1 (single-user, one turn at a time) but would become a problem with concurrent turns or if agent execution takes a long time.

---

## 7. Meta-Tools (dispatch_agent, get_agent_results, get_skill, send_agent_update)

**Verdict: Well-factored, appropriate coupling level**

### Strengths
- Each meta-tool is a self-contained module with `tool_definition/0` + `execute/2` — consistent contract
- dispatch_agent creates ExecutionLog records for audit trail
- get_agent_results supports both polling and blocking wait modes (`wait_any`/`wait_all`)
- send_agent_update integrates cleanly with SubAgent.resume/2

### Findings

**[Minor] M-MT-1: send_agent_update calls SubAgent.resume directly**
The send_agent_update tool in LoopRunner (`route_tool_call` at loop_runner.ex:193) calls `SendAgentUpdate.execute(args, nil)` passing `nil` as context. The actual resume happens through the SubAgent.resume/2 call inside SendAgentUpdate. This works but means the resume happens synchronously during the LLM loop iteration. If the sub-agent is slow to resume, it blocks the orchestrator loop.

---

## 8. Memory System Architecture (ContextMonitor + TurnClassifier + MemoryAgent)

**Verdict: Clean event-driven design with appropriate decoupling**

### Strengths
- PubSub-based decoupling: Engine broadcasts events, monitors subscribe — zero coupling between orchestrator and memory system
- ContextMonitor uses a cooldown timer (60s) to prevent rapid-fire compaction dispatch — good operational defense
- TurnClassifier offloads classification to `Task.Supervisor.start_child` — non-blocking, crash-isolated
- Search-first enforcement (SkillExecutor) is architectural, not just instructional — the LLM literally cannot bypass it
- Two-trigger compaction: utilization-based (ContextMonitor) + topic-change-based (TurnClassifier) covers both scenarios

### Findings

**[Minor] M-MEM-1: TurnClassifier dispatches two missions for save_facts, second is always dropped**
`turn_classifier.ex:123-138` — When classified as `save_facts`, the classifier dispatches both `:save_memory` and `:extract_entities` missions via two sequential `GenServer.cast` calls. But MemoryAgent can only handle one mission at a time. The second cast will hit the busy-drop handler (M-MA-1). These two operations need to be combined into a single compound mission, or the agent needs queuing.

**[Minor] M-MEM-2: TurnClassifier hardcodes OpenRouter client**
`turn_classifier.ex:103` — Calls `OpenRouter.chat_completion` directly instead of using the `@llm_client` module attribute pattern used everywhere else. This breaks the Mox-based testing pattern and means TurnClassifier can't be tested without network access.

---

## 9. Context Trimming Logic (context.ex)

**Verdict: Correct and well-reasoned hybrid approach**

### Strengths
- Two strategies: pure estimation (first turn, no baseline) and usage-based (subsequent turns, `prompt_tokens` from API response as baseline)
- Usage-based approach only estimates *new* messages (added since last LLM call), using the actual `prompt_tokens` as ground truth for known messages — this is significantly more accurate than re-estimating everything
- Trim strategy preserves newest messages (tool results, dispatches) and drops oldest known messages first — correct priority
- 4 chars/token heuristic with +4 overhead per message is a reasonable approximation

### Findings

**[Minor] M-CTX-1: Tool call messages not accounted for in token estimation**
`context.ex:314-326` — `estimate_message_tokens` only looks at `content` fields. Messages with `tool_calls` (the assistant messages that contain function call arrays) have no `content` text but consume significant tokens (function name, arguments JSON). These would be estimated at ~4 tokens (just the framing overhead). In practice, the usage-based path compensates for this since the API reports actual token counts, but the pure-estimation fallback under-counts tool-heavy histories.

---

## 10. Circuit Breaker Hierarchy (resilience/)

**Verdict: Comprehensive four-level design, correct implementation**

### Strengths
- Level 1 (per-skill, via `:fuse`): Well-chosen library, auto-install on first access is resilient
- Level 2 (per-agent): Simple counter threaded through state — low overhead, correct
- Level 3 (per-turn): Separate agent and skill call limits — appropriate granularity
- Level 4 (per-conversation): Sliding window via RateLimiter — correct temporal protection
- Limits facade module provides consistent API with `defdelegate` — clean layering
- `check_all/4` combined check with short-circuit semantics — exists and correct

### Findings

**[Minor — duplicate of M-ENG-2] Level 4 not enforced in the loop**
As noted in M-ENG-2, the `check_conversation` level is defined and tested but not called during orchestration. This makes the sliding window rate limit dead code in Phase 1.

---

## 11. Interface Contracts and Coupling Assessment

### Well-Defined Boundaries

| Boundary | Interface | Coupling |
|----------|-----------|----------|
| Engine <-> LoopRunner | Tagged tuples (`{:text, ...}`, `{:tool_calls, ...}`, `{:wait, ...}`) | Loose |
| Engine <-> SubAgent | `SubAgent.execute/3` returns map | Loose |
| Engine <-> AgentScheduler | `execute/3` with function callback | Very loose |
| SubAgent <-> Skills | `Executor.execute/4` -> `{:ok, Result}` | Loose via behaviour |
| Config.Loader <-> consumers | ETS reads, no coupling to GenServer | Very loose |
| Engine <-> Memory system | PubSub broadcasts, no direct calls | Very loose |
| MemoryAgent <-> SkillExecutor | `execute/6` with session state threading | Appropriate |

### Coupling Concerns

**None blocking.** The most tightly coupled area is the tool-call parsing helpers (duplicated across 3 modules — M-SA-3), which is a DRY issue not a coupling issue. The meta-tools are appropriately coupled to the components they operate on (DispatchAgent knows about ExecutionLog, GetAgentResults knows about dispatched_agents map structure).

---

## 12. Cross-Cutting Concerns

### Logging
Comprehensive structured logging throughout. Every significant state transition, error, and decision point is logged with relevant metadata (agent_id, conversation_id, skill_name, etc.). Logger levels are appropriate (info for state changes, warning for degraded paths, error for failures).

### Error Handling
Consistent `{:ok, ...} | {:error, ...}` tuple pattern throughout. Errors propagate cleanly through the chain. The Nudger system for error-to-hint mapping is an elegant way to give the LLM actionable recovery guidance without hardcoding hints at error sites.

### Testability
The `@llm_client Application.compile_env(...)` pattern enables Mox-based testing for SubAgent, MemoryAgent, and LoopRunner. Skills execute under Task.Supervisor with timeout — testable in isolation. Config and prompts can be initialized with test data via opts.

---

## Finding Summary

### Blocking: 0

### Minor: 13

| ID | Component | Description |
|----|-----------|-------------|
| M-SUP-1 | application.ex:40 | Hardcoded `user_id: "dev-user"` for MemoryAgent |
| M-SA-1 | sub_agent.ex:501-523 | `receive` block in Task has no timeout |
| M-SA-2 | sub_agent.ex:1047-1052 | Race condition in `wait_for_completion` loses result |
| M-SA-3 | sub_agent/agent/loop_runner | ~60 lines of duplicated response parsing helpers |
| M-MA-1 | agent.ex:313-323 | Busy missions silently dropped; no queue |
| M-MA-2 | agent.ex:507-521 | Same receive-without-timeout as M-SA-1 |
| M-MA-3 | agent.ex:580 | Sentinel match-assert will crash on Phase 2 rejections |
| M-CFG-1 | loader.ex:274, prompt_loader.ex:194 | `String.to_atom/1` on YAML keys without bounds |
| M-CFG-2 | prompt_loader.ex:273 | `Code.eval_quoted` for template rendering (local files = safe) |
| M-ENG-1 | engine.ex:102 | 120s call timeout; no cleanup on caller timeout |
| M-ENG-2 | engine.ex (init) | Level 4 circuit breaker defined but not enforced |
| M-MEM-1 | turn_classifier.ex:123-138 | Sequential dual dispatch always drops second mission |
| M-MEM-2 | turn_classifier.ex:103 | Hardcoded OpenRouter client breaks Mox testing pattern |
| M-CTX-1 | context.ex:314-326 | Tool call messages under-estimated in pure-estimation path |
| M-MT-1 | loop_runner.ex:193 | send_agent_update resume is synchronous in loop |

### Future: 3

| ID | Component | Description |
|----|-----------|-------------|
| F-SUP-1 | application.ex | Restart strategy tuning for production |
| F-SUP-2 | application.ex | Config.Watcher not yet wired (tracked in Task #32) |
| F-SK-1 | skills/registry.ex | No handler module validation at registration time |

---

## Overall Assessment

**Recommendation: Approve (no blocking issues)**

The Phase 1 foundation is architecturally sound. The OTP patterns are used correctly, component boundaries are clear, and the interface contracts are well-defined. The skill system is extensible, the circuit breaker hierarchy is comprehensive, and the memory system's event-driven design provides clean decoupling.

The minor findings are typical of a Phase 1 foundation — timeouts, race conditions on edge paths, and a few DRY violations. M-MEM-1 (dual dispatch always dropping second mission) and M-ENG-2 (Level 4 not enforced) are the most impactful minors and should be addressed early in Phase 2.

The architecture provides a solid base for multi-user scaling, additional skill domains, and the Phase 2 Sentinel implementation.

---

## Verification Pass: Minor Item Fixes (Commits 0510da2, 53820dc)

**Date**: 2026-02-18
**Scope**: Verify-only re-review of specific minor items M1-M8 + F3 tests

### M1: TurnClassifier sends single `:save_and_extract` cast (was M-MEM-1)

**Status: RESOLVED**

`turn_classifier.ex:122-135` — The `save_facts` classification branch now dispatches a single `:save_and_extract` mission (line 128) instead of the previous two sequential casts (`:save_memory` + `:extract_entities`). The MemoryAgent's `build_mission_text/2` at `agent.ex:829-849` handles the combined `:save_and_extract` action with a unified 8-step instruction set covering both saving and entity extraction. This eliminates the race condition where the second cast would be silently dropped when the agent was busy processing the first.

### M2: L4 circuit breaker `check_conversation/2` wired into engine `run_loop`

**Status: RESOLVED**

`engine.ex:241-257` — The `run_loop/1` function now calls `Limits.check_conversation(state.conversation_state)` at the top of each iteration, before invoking `LoopRunner.run_iteration/3`. On `{:error, :limit_exceeded, details}`, it returns an error message to the user instead of proceeding. The loop iteration logic was extracted to `run_loop_iteration/1` for clarity. This enforces the Level 4 sliding-window rate limiter that was previously defined but never checked.

### M3: Receive timeouts (5 min) added to SubAgent + MemoryAgent

**Status: RESOLVED**

- `sub_agent.ex:506-546` — The `receive` block in the Task-based LLM loop now has `after 300_000` (5 minutes). On timeout, it logs a warning and returns a failure result. A `{:shutdown, reason}` message handler is also present for clean shutdown.
- `agent.ex:507-540` — The MemoryAgent's `receive` block for orchestrator resume likewise has `after 300_000`. On timeout, it logs and returns a failed status with "Timed out waiting for orchestrator response (5 minutes)." A `{:shutdown, reason}` handler returns a clean failure.

Both implementations follow the same pattern and prevent indefinite blocking of Task processes.

### M4: `@llm_client` injection in TurnClassifier (was M-MEM-2)

**Status: RESOLVED**

`turn_classifier.ex:39-43` — Now uses `@llm_client Application.compile_env(:assistant, :llm_client, Assistant.Integrations.OpenRouter)`, matching the pattern established in SubAgent, MemoryAgent, and LoopRunner. Line 108 calls `@llm_client.chat_completion(...)` instead of the previously hardcoded `OpenRouter.chat_completion(...)`. This enables Mox-based test isolation.

### M5: PromptLoader EEx warnings resolved in tests

**Status: RESOLVED**

`prompt_loader_test.exs:94-104` — The "renders empty interpolations for missing variables" test previously passed an empty map `%{}` as assigns, which triggered EEx "assign not available" warnings at test runtime. The fix passes `%{skill_domains: "", user_id: "", current_date: ""}` — all expected keys with empty string values. This eliminates the warnings while still testing the "empty variable" behavior. The updated comment on lines 96-98 documents the rationale.

### M6: Encryption TODO on `notification_channel.config`

**Status: RESOLVED**

`schemas/notification_channel.ex:5-6` — The moduledoc now explicitly states: "Config is stored as binary; Cloak.Ecto encryption is planned but not yet wired." Line 18-19 has the inline TODO comment: `# TODO: encrypt with Cloak.Ecto before storing real credentials`. The field type is `:binary`, which is the correct base type for a future Cloak.Ecto encrypted field (Cloak encrypts to binary). The TODO is clear and the schema is structured for a non-breaking upgrade path.

### M7: LLMHelpers module extracted (was M-SA-3)

**Status: RESOLVED**

`llm_helpers.ex` (151 lines) — New module `Assistant.Orchestrator.LLMHelpers` consolidates the duplicated response parsing helpers:
- `resolve_model/1` — model resolution from config
- `build_llm_opts/2` — keyword list construction with tools and optional model
- `text_response?/1`, `tool_call_response?/1` — response type predicates
- `extract_function_name/1`, `extract_function_args/1` — tool call field extraction (handles both atom-keyed and string-keyed maps, both pre-decoded and JSON-string arguments)
- `extract_last_assistant_text/1` — walks messages backward for last assistant content

Delegation verified in all three consumers:
- `sub_agent.ex:1166` uses `LLMHelpers.resolve_model(:sub_agent)`, lines 1181-1185 delegate parsing functions
- `agent.ex:891-892` delegates `build_model_opts` through `LLMHelpers.resolve_model` and `LLMHelpers.build_llm_opts`; lines 926-932 delegate all five parsing helpers
- `loop_runner.ex:76` uses `LLMHelpers.resolve_model(:orchestrator)`, line 80 uses `LLMHelpers.build_llm_opts`, lines 122-123 delegate response predicates, line 161 uses `LLMHelpers.extract_function_name`, line 162 uses `LLMHelpers.extract_function_args`

### M8: Turn-boundary context trimming

**Status: RESOLVED**

`context.ex:224-298` — The `trim_messages/4` function now implements a hybrid strategy:

1. **Usage-based (preferred)**: When `last_prompt_tokens` is available (from the prior API response), it uses the actual token count as a baseline for known messages and only estimates deltas for new messages added since the last LLM call. `trim_messages_by_usage/4` (lines 272-298) splits messages into known vs. new, estimates only new tokens, and trims oldest known messages first if over budget.

2. **Pure estimation (fallback)**: For the first message in a conversation (no prior usage data), `trim_messages_by_estimation/2` (lines 253-268) walks newest-first, accumulating estimated tokens at ~4 chars/token.

Both strategies operate on whole turns (user + subsequent assistant/tool messages) via `group_into_turns/1` (lines 322-342) to avoid orphaned assistant responses or tool results. The `compute_history_token_budget/1` (lines 210-222) computes available budget from model context window, utilization target, and response reserve.

The Engine passes `last_prompt_tokens` and `last_message_count` through `loop_state` to enable the usage-based path.

### F3: New test files present (64+ tests, 1025 insertions)

**Status: RESOLVED**

Commit 53820dc adds 6 new test files and modifies 1:

| File | Tests | Lines |
|------|-------|-------|
| `test/assistant/orchestrator/loop_runner_test.exs` | 7 | 97 |
| `test/assistant/orchestrator/tools/dispatch_agent_test.exs` | 7 | 166 |
| `test/assistant/orchestrator/tools/get_agent_results_test.exs` | 18 | 321 |
| `test/assistant/orchestrator/tools/get_skill_test.exs` | 8 | 128 |
| `test/assistant/orchestrator/tools/send_agent_update_test.exs` | 7 | 98 |
| `test/assistant/integrations/openrouter_test.exs` | 19 | 211 |
| `test/assistant/config/prompt_loader_test.exs` (modified) | — | 6 (net) |
| **Total** | **66** | **1,025** |

All 6 new test files cover previously untested modules (the four meta-tools, LoopRunner, and OpenRouter client). The count of 66 test cases exceeds the stated 64 target.

### New Issues Introduced: None

No new architectural concerns were introduced by these fixes. The LLMHelpers extraction is clean, the delegation pattern is consistent, and the context trimming hybrid approach is well-structured.

### Verification Summary

| Item | Status |
|------|--------|
| M1: Compound `:save_and_extract` mission | Resolved |
| M2: L4 circuit breaker enforcement | Resolved |
| M3: Receive timeouts (5 min) | Resolved |
| M4: `@llm_client` injection in TurnClassifier | Resolved |
| M5: PromptLoader EEx test warnings | Resolved |
| M6: Encryption TODO documented | Resolved |
| M7: LLMHelpers extraction | Resolved |
| M8: Turn-boundary context trimming | Resolved |
| F3: 64+ new tests (1,025 insertions) | Resolved (66 tests) |

**All 9 items verified as resolved. No new issues introduced.**
