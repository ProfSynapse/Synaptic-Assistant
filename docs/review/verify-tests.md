# Test Fix Verification Report

**Date**: 2026-02-18
**Verifier**: pr-test-engineer
**Scope**: Blocking findings B1 and B2 from test-engineer-review.md

## Finding Verification

### B1: SubAgent @tag :skip (6 tests) -- Resolved

**Commit**: 71b7e27 (unskip) + e02349b (ConfigLoader setup)

- **Grep confirmation**: 0 occurrences of `@tag :skip` in `test/assistant/orchestrator/sub_agent_test.exs`
- **Outdated bug comment block** (lines 28-38 describing Registry alias issue) removed
- **Additional fix required**: Commit 88405ae (backend coder B2 fix) made `SubAgent.build_model_opts` call `Config.Loader.model_for`, which requires the `:assistant_config` ETS table. Added `ensure_config_loader_started()` to test setup in commit e02349b.
- **All 13 SubAgent tests pass** in both isolated and full-suite runs

### B2: ErrorJSONTest ConnCase dependency -- Resolved

**Commit**: 71b7e27

- **Grep confirmation**: 0 occurrences of `ConnCase` in `test/assistant_web/controllers/error_json_test.exs`
- Line 2 now reads `use ExUnit.Case, async: true`
- **Both ErrorJSON tests pass** (renders 404, renders 500)

## Full Suite Results

```
226 tests, 4 failures, 0 skipped
```

**Excluded**: `health_controller_test.exs` (requires DB/Ecto -- pre-existing, out of scope)

**4 failures** -- all pre-existing `Assistant.Memory.AgentTest` (ETS `:assistant_config` missing):
1. `test mission completion agent returns to idle after LLM error` (agent_test.exs:167)
2. `test mission completion missions_completed increments after dispatch cycle` (agent_test.exs:184)
3. `test handle_cast {:mission, action, params} save_memory cast accepted from idle state` (agent_test.exs:122)
4. `test dispatch/2 returns :ok when idle (transitions to running)` (agent_test.exs:101)

These are the same 4 failures reported in the original test-engineer-review.md. They are NOT regressions from the B1/B2 fixes. Root cause: `AgentTest` setup does not start `Config.Loader`, so `build_model_opts` crashes on missing ETS. Same pattern as the SubAgent issue fixed in e02349b, but for a different test file (out of scope for this task).

## Commits

| Commit | Description |
|--------|-------------|
| 71b7e27 | Remove 6 `@tag :skip` + outdated bug comment; change ErrorJSONTest to ExUnit.Case |
| e02349b | Add `ensure_config_loader_started()` to SubAgent test setup (interaction with B2 backend fix) |
