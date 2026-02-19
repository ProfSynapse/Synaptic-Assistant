# Test Engineer Review — PR #1: Skills-First Assistant Foundation

**Reviewer**: PACT Test Engineer
**Date**: 2026-02-18
**Risk Tier**: HIGH (novel OTP patterns, multi-level circuit breaker, LLM orchestration loop)

---

## Test Suite Summary

| Metric | Value |
|--------|-------|
| Total tests | 228 |
| Passing | 218 |
| Failing | 4 (all DB-dependent web controller tests — environment issue) |
| Skipped | 6 (SubAgent GenServer tests — known alias shadowing bug) |
| Test files | 18 |
| Source files | 55 (.ex) |

### Test Run Configuration

Tests run with `--no-start` + manual OTP app bootstrapping due to no PostgreSQL available. All 4 failures are `HealthControllerTest` and `ErrorJSONTest` — they use `ConnCase` which requires Ecto sandbox, unavailable without DB. These are **not** code defects; they would pass in CI with a running database.

---

## Signal Output

```
Risk Tier: HIGH
Signal: YELLOW
Coverage: ~65% of critical paths (estimated)
Uncertainty Coverage: 4 of 6 HIGH areas tested
Findings: Major gaps in Engine/LoopRunner/OpenRouter/Tools; SubAgent tests all skipped; weak assertions in several test files
```

---

## Coverage Analysis by Module

### Well-Tested Modules (GREEN)

| Module | Test File | Tests | Assessment |
|--------|-----------|-------|------------|
| `CircuitBreaker` (240 LOC) | `circuit_breaker_test.exs` | 20 | All 4 levels tested. `check_all/4` short-circuiting verified. Sliding window expiry tested with `Process.sleep`. Solid. |
| `RateLimiter` (116 LOC) | `rate_limiter_test.exs` | 11 | Pure functional module. Multi-count, pruning, expiry, reset all tested. |
| `Skills.Registry` (258 LOC) | `registry_test.exs` | 18 | GenServer lifecycle, ETS lookups, domain indexes, search (case-insensitive, by tag/description/name), empty dir. Good cleanup patterns. |
| `CLIExtractor` (~120 LOC) | `cli_extractor_test.exs` | 13 | Good edge cases: nil input, empty string, non-cmd blocks, whitespace stripping, multiple blocks. |
| `CLIParser` (~180 LOC) | `cli_parser_test.exs` | 16 | Tokenizer well-tested: quotes, equals flags, errors for unterminated quotes, mixed tokens. |
| `Config.Loader` (~300 LOC) | `loader_test.exs` | 10 | Full lifecycle: start, model_for, http_config, limits_config, env var interpolation, reload, invalid reload preservation. |
| `PromptLoader` (~280 LOC) | `prompt_loader_test.exs` | 10 | Render, render_section, get_raw, boot edge cases (missing dir, empty dir, malformed YAML), reload. |
| `Skills.Executor` (108 LOC) | `executor_test.exs` | 4 | Success, error, crash, timeout all tested. Good `build_handler` pattern using Module.create + named ETS. |
| `Memory.SkillExecutor` (~100 LOC) | `skill_executor_test.exs` | 17 | CRITICAL INVARIANT (search-first) thoroughly tested. All write skills rejected without prior read. Multiple writes after single read. Session reset. Non-memory passthrough. |
| `AgentScheduler` (~200 LOC) | `agent_scheduler_test.exs` | 16 | DAG resolution (Kahn's) well-tested: diamond, chain, cycle detection, unknown deps. Wave execution with dep passing, crash capture, transitive skip. `wait_for_agents` tested. |

### Partially Tested Modules (YELLOW)

| Module | Issue |
|--------|-------|
| `Memory.Agent` (agent_test.exs, 8 tests) | Tests GenServer lifecycle (start, register, dispatch, resume, mission completion). However, all LLM paths fail-fast because no mock client is configured — only the error recovery path is exercised. The happy path (successful mission completion with tool calls) is never tested. |
| `Memory.TurnClassifier` (turn_classifier_test.exs, 10 tests) | PubSub subscription tested. Event handling tested at process-alive level only. Classification parsing tests are contract-only (testing the expected JSON shape, not calling the private `parse_classification` function). Tests for "save_facts triggers save_memory + extract_entities" are tautological assertions on local variables, not actual behavior. |
| `Memory.ContextMonitor` (context_monitor_test.exs, 5 tests) | PubSub subscription tested. Threshold dispatch is tested indirectly (process stays alive), but actual dispatch to memory agent is not verified — the mock registration approach does not capture GenServer.cast delivery. Cooldown deduplication asserts process-alive only. |
| `Orchestrator.Context` (context_test.exs, 6 tests) | Tests reimplemented trimming logic as test helpers rather than calling the actual module functions. This means the tests verify the **specification** but not the **implementation**. If Context.trim_messages diverges from the helper, tests would still pass. |
| `Sentinel` (sentinel_test.exs, 5 tests) | Phase 1 stub (always approves) — tests are appropriate for a stub but provide no security gate coverage. Noted as expected for Phase 1. |

### Untested Modules (RED)

| Module | LOC | Criticality | Impact |
|--------|-----|-------------|--------|
| `Orchestrator.Engine` | 555 | **CRITICAL** | Heart of the system. `send_message`, `run_loop`, `handle_tool_calls`, `handle_wait`, `handle_dispatches`, `accumulate_usage`, PubSub broadcasts — zero test coverage. |
| `Orchestrator.LoopRunner` | 273 | **CRITICAL** | Pure-function LLM loop logic. `run_iteration`, `process_response`, `route_tool_call`, `format_tool_results`, `format_assistant_tool_calls` — zero test coverage. This is explicitly designed to be "stateless and testable" per its header comment, making the absence of tests particularly notable. |
| `Integrations.OpenRouter` | 595 | **HIGH** | LLM HTTP client. `chat_completion`, streaming, tool formatting, prompt caching, retry logic, reasoning trace stripping — zero test coverage. |
| `Orchestrator.Nudger` | 196 | STANDARD | Error-to-hint mapping. Pure functional lookups — straightforward to test but untested. |
| `Orchestrator.Limits` | 212 | LOW | Thin defdelegate facade over CircuitBreaker. CircuitBreaker itself is well-tested, so risk is low. |
| `Tools.GetSkill` | 277 | STANDARD | Progressive disclosure tool. Pure function — readily testable but untested. |
| `Tools.DispatchAgent` | 304 | HIGH | Dispatch validation, skill existence check, limit enforcement — untested. |
| `Tools.GetAgentResults` | 327 | STANDARD | Result collection and formatting — untested. |
| `Tools.SendAgentUpdate` | 203 | LOW | Simple agent-to-agent update tool — untested. |
| `Orchestrator.SubAgent` | 1179 | **CRITICAL** | Largest module. GenServer lifecycle, LLM loop, scope enforcement, skill execution, request_help flow — **all 6 tests are skipped** due to the `Registry` alias shadowing bug (line 66 aliases `Assistant.Skills.Registry`, shadowing `Elixir.Registry` in `via_tuple/1`). |

---

## Findings

### Blocking

**B1. SubAgent alias shadowing bug causes all SubAgent tests to skip** (`lib/assistant/orchestrator/sub_agent.ex:66`, `test/assistant/orchestrator/sub_agent_test.exs:41`)

The `alias Assistant.Skills.{..., Registry, ...}` at line 66 of `sub_agent.ex` shadows `Elixir.Registry`. The `via_tuple/1` function at line ~94 uses `{:via, Registry, ...}` which resolves to `Assistant.Skills.Registry` instead of `Elixir.Registry`, causing `UndefinedFunctionError: Assistant.Skills.Registry.whereis_name/1`. All 6 SubAgent tests are `@tag :skip` because of this. This is a **production bug** — SubAgent.start_link will crash at runtime.

**Fix**: Change `Registry` to `Elixir.Registry` in `via_tuple/1`, or rearrange the alias.

**B2. Web controller tests fail without database** (`test/assistant_web/controllers/error_json_test.exs`, `test/assistant_web/controllers/health_controller_test.exs`)

`ErrorJSONTest` does not need a database connection — it calls `ErrorJSON.render/2` directly. But it `use`s `ConnCase` which triggers Ecto sandbox setup. These tests should use a lighter setup (plain `ExUnit.Case`) since they don't make HTTP requests. `HealthControllerTest` genuinely needs the endpoint running, so that failure is expected without DB.

**B3. PromptLoader.render/2 emits EEx warnings for missing assigns** (`test/assistant/config/prompt_loader_test.exs:98`)

The test "renders empty interpolations for missing variables" calls `PromptLoader.render(:orchestrator, %{})` which triggers multiple `warning: assign @X not available in EEx template` warnings during test execution. The test passes (EEx renders nil as empty string), but these warnings in the test output are noisy and the behavior is fragile — a stricter EEx configuration would cause this to fail.

### Minor

**M1. Context trimming tests verify reimplemented logic, not actual module** (`test/assistant/orchestrator/context_test.exs`)

The test file reimplements `trim_by_estimation` and `trim_by_usage` as private test helpers and tests those. If the actual `Context` module's implementation diverges (different formula, off-by-one), these tests would still pass. The test file header acknowledges this limitation.

**Recommendation**: Extract `estimate_message_tokens/1` and `trim_messages/2` as public (or `@doc false`) functions on the Context module, then test them directly.

**M2. TurnClassifier classification tests are tautological** (`test/assistant/memory/turn_classifier_test.exs:106-124`)

The "classification action contracts" tests create local variables and assert on them:
```elixir
actions_for_save_facts = [:save_memory, :extract_entities]
assert length(actions_for_save_facts) == 2
```
This tests the test itself, not the module. The actual `parse_classification/1` private function behavior is never verified.

**Recommendation**: Extract `parse_classification/1` or `actions_for/1` as a public function and test it with actual JSON input strings.

**M3. ContextMonitor dispatch not actually verified** (`test/assistant/memory/context_monitor_test.exs:80-119`)

The "at threshold" test registers a mock agent and broadcasts an above-threshold event, but never verifies that `GenServer.cast(pid, {:mission, :compact_conversation, ...})` was actually sent. It only checks the process is alive. The mock_agent `Agent` is never queried for received messages.

**M4. SubAgent scope enforcement tests are structural assertions only** (`test/assistant/orchestrator/sub_agent_test.exs:198-262`)

Tests like "scoped tool enum restricts skill names" and "dual scope enforcement" assert on data structures (e.g., `"email.send" not in dispatch_params.skills`) without ever calling SubAgent functions. These verify the test data, not SubAgent behavior.

**M5. Deprecated `use Phoenix.ConnTest` warning** (`test/assistant_web/controllers/error_json_test.exs:2`, `test/assistant_web/controllers/health_controller_test.exs:6`)

Both web test files trigger deprecation warnings:
```
warning: Using Phoenix.ConnTest is deprecated, instead of:
    use Phoenix.ConnTest
do:
    import Plug.Conn
    import Phoenix.ConnTest
```

**M6. Compiler warning about dead code branch** (`lib/assistant/orchestrator/sub_agent.ex:587`)

The `{:ok, {:rejected, reason}}` clause in `execute_use_skill/4` can never match because `Sentinel.check/3` is a stub that always returns `{:ok, :approved}`. The compiler correctly identifies this as dead code. This is expected for Phase 1 but should be addressed when Sentinel gains real logic.

### Future

**F1. No test coverage for Engine + LoopRunner** (~828 LOC combined)

These are the two most critical modules in the system and have zero tests. `LoopRunner` is explicitly designed as a pure-function module "extracted from the Engine GenServer to be stateless and testable" — it should be the highest-priority target for unit tests. Key test scenarios:

- `run_iteration` with mocked LLM client returning text-only response
- `run_iteration` with tool calls (get_skill, dispatch_agent, get_agent_results)
- `process_response` with edge cases: no content + no tool calls, content + tool calls
- `route_tool_call` with unknown tool name
- `extract_tool_name` and `extract_tool_args` with atom vs string keys, malformed JSON
- `format_tool_results` and `format_assistant_tool_calls`

Engine tests require more infrastructure (LLM mock + PubSub + registries) but should cover:
- `send_message` happy path with mocked LLM
- Max iteration limit hit
- Circuit breaker enforcement during dispatch
- PubSub broadcasts for token usage and turn completion

**F2. No test coverage for OpenRouter client** (595 LOC)

The HTTP client handles streaming, retries, reasoning trace stripping, tool sorting, and prompt caching. None of this is tested. For Phase 1 (no production traffic), this is acceptable, but it must be tested before any real deployment. Priority areas:

- Reasoning trace stripping (regex-based, error-prone)
- Tool definition sorting (cache key stability)
- Retry backoff logic
- Error response parsing
- Streaming SSE assembly

**F3. No test coverage for meta-tools** (GetSkill 277 LOC, DispatchAgent 304 LOC, GetAgentResults 327 LOC, SendAgentUpdate 203 LOC)

All four orchestrator tools are untested. `GetSkill` and `GetAgentResults` are pure functions that could be trivially unit-tested. `DispatchAgent` has validation logic and limit checking that should be tested.

**F4. No test coverage for Nudger** (196 LOC)

Pure functional module with simple lookup/format logic. Easy to test but currently has zero tests. Low risk since it's a hint-only system (doesn't affect correctness).

**F5. MemoryAgent/TurnClassifier/ContextMonitor need LLM mock tests**

All three memory system GenServers test only the error recovery path (LLM call fails, process survives). The happy path — where the LLM returns a valid classification or the agent completes a mission — is never exercised. Adding `Mox` or a test double for the LLM client would enable these tests.

---

## Test Quality Assessment

### Strengths

1. **Good ETS/GenServer cleanup patterns**: Registry tests properly stop processes, delete ETS tables, and guard against `ArgumentError` on already-deleted tables.
2. **Process unlinking for shared infrastructure**: `start_unlinked` pattern correctly used in MemoryAgent, TurnClassifier, and ContextMonitor tests to prevent PubSub/Registry from dying between tests.
3. **Named ETS + Module.create for test handlers**: The `build_handler` pattern in `executor_test.exs` is a well-known solution for dynamic test modules in Elixir.
4. **Deterministic circuit breaker tests**: Level 2-4 tests use pure state manipulation without time dependencies (except the sliding window test, which uses a short window + sleep).
5. **Search-first invariant thoroughly tested**: The `SkillExecutor` tests exhaustively cover the critical business rule with every write skill, session reset, and passthrough scenarios.
6. **AgentScheduler DAG tests are comprehensive**: Diamond graph, cycles, unknown deps, transitive skip on failure, crash capture — all tested.

### Weaknesses

1. **Process-alive assertions are too weak**: Multiple tests (TurnClassifier, ContextMonitor) only assert `Process.alive?(pid)` after sending events. This proves the process didn't crash but not that it did the right thing.
2. **Context trimming tests don't test actual implementation**: Reimplemented as test helpers — spec tests, not implementation tests.
3. **No LLM mocking infrastructure**: The project uses `Application.compile_env(:assistant, :llm_client)` for testability but never sets up a mock. This means all LLM-dependent paths are untested.
4. **Tautological assertion pattern**: Several tests assert on locally-constructed variables rather than calling module functions.
5. **No `mix test --cover` or `excoveralls` configured**: No coverage metrics available. Coverage analysis is based on manual review.

---

## Recommendations

### For Phase 1 Merge (Minimum)

1. **Fix the SubAgent alias bug (B1)** — This is a production crash. Change `Registry` to `Elixir.Registry` in `via_tuple/1` and unskip the 6 SubAgent tests.
2. **Fix ErrorJSONTest setup (B2)** — Use plain `ExUnit.Case` instead of `ConnCase` for tests that don't need HTTP connections.
3. **Add LoopRunner unit tests (F1)** — The module is explicitly pure-function and designed for testing. Even 5-10 tests for `extract_tool_name`, `extract_tool_args`, `format_tool_results`, and `format_assistant_tool_calls` would significantly increase confidence.

### For Phase 2

1. Set up `Mox` for `LLMClient` behaviour and add Engine + SubAgent integration tests.
2. Add `excoveralls` for CI coverage tracking.
3. Test all four meta-tools (GetSkill, DispatchAgent, GetAgentResults, SendAgentUpdate).
4. Add OpenRouter client tests with HTTP mocking (Bypass or Req test adapter).
5. Extract and directly test Context.trim_messages and TurnClassifier.parse_classification.

---

## Appendix: Test File Index

| Test File | Module Under Test | Test Count | async |
|-----------|-------------------|------------|-------|
| `registry_test.exs` | Skills.Registry | 18 | false |
| `executor_test.exs` | Skills.Executor | 4 | true |
| `circuit_breaker_test.exs` | Resilience.CircuitBreaker | 20 | false |
| `rate_limiter_test.exs` | Resilience.RateLimiter | 11 | true |
| `cli_extractor_test.exs` | Orchestrator.CLIExtractor | 13 | true |
| `cli_parser_test.exs` | Orchestrator.CLIParser | 16 | true |
| `context_test.exs` | Orchestrator.Context | 6 | true |
| `sentinel_test.exs` | Orchestrator.Sentinel | 5 | true |
| `agent_scheduler_test.exs` | Orchestrator.AgentScheduler | 16 | true |
| `sub_agent_test.exs` | Orchestrator.SubAgent | 12 (6 skipped) | false |
| `skill_executor_test.exs` | Memory.SkillExecutor | 17 | true |
| `turn_classifier_test.exs` | Memory.TurnClassifier | 10 | false |
| `agent_test.exs` | Memory.Agent | 8 | false |
| `context_monitor_test.exs` | Memory.ContextMonitor | 5 | false |
| `loader_test.exs` | Config.Loader | 10 | false |
| `prompt_loader_test.exs` | Config.PromptLoader | 10 | false |
| `health_controller_test.exs` | HealthController | 2 (fail w/o DB) | true |
| `error_json_test.exs` | ErrorJSON | 2 (fail w/o DB) | true |
| **Total** | | **228** | |
