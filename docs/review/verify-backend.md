# Backend Blocking Issues — Verification Report

**Reviewer**: pr-backend-coder
**Date**: 2026-02-18
**Commit verified**: 88405ae (`fix: model resolution, SubAgent result capture, Sentinel match safety`)

---

## B1: SubAgent `wait_for_completion` result capture

**Status**: Resolved

**Evidence**:
- `lib/assistant/orchestrator/sub_agent.ex:382` — Both the normal-completion handler (`handle_info({ref, result}, ...)`) and the crash handler (`handle_info({:DOWN, ref, ...}`) now stop with `{:stop, {:shutdown, build_final_result_map(final_state)}, final_state}` instead of `{:stop, :normal, ...}`.
- `lib/assistant/orchestrator/sub_agent.ex:1068-1105` — `wait_for_completion/2` matches `{:DOWN, ^monitor_ref, :process, _pid, {:shutdown, %{status: _} = result_map}}` to extract the real result from the stop reason. Also handles the `{:shutdown, {:error, {:context_budget_exceeded, _}}}` edge case, a `:normal` fallback (should not occur but is defensive), and a catch-all for unexpected exit reasons.
- `lib/assistant/orchestrator/sub_agent.ex:1107-1114` — New `build_final_result_map/1` helper constructs the map with `status`, `result`, `tool_calls_used`, `duration_ms`.
- The old `fetch_from_registry_or_default/1` function (which returned a static fallback) has been removed.

---

## B2: SubAgent missing `:model` in LLM opts

**Status**: Resolved

**Evidence**:
- `lib/assistant/orchestrator/sub_agent.ex:1145-1162` — `build_model_opts/2` now resolves the model via `Loader.model_for(:sub_agent)` when `dispatch_params[:model_override]` is nil, extracting the `:id` field from the config map. When an override is provided, it uses that. The model is included in the keyword list via `Keyword.put(opts, :model, model)` when non-nil.

---

## B3: MemoryAgent missing `:model` in LLM opts

**Status**: Resolved

**Evidence**:
- `lib/assistant/memory/agent.ex:83` — `Loader` alias added: `alias Assistant.Config.{Loader, PromptLoader}`.
- `lib/assistant/memory/agent.ex:848-857` — `build_model_opts/1` now resolves via `Loader.model_for(:sub_agent)`, extracts `:id`, and includes `:model` in the keyword list when non-nil. Same pattern as the SubAgent fix.

---

## B4: LoopRunner missing `:model` in LLM opts

**Status**: Resolved

**Evidence**:
- `lib/assistant/orchestrator/loop_runner.ex:38` — `ConfigLoader` alias added: `alias Assistant.Config.Loader, as: ConfigLoader`.
- `lib/assistant/orchestrator/loop_runner.ex:74-84` — `run_iteration/3` now resolves the model from `ConfigLoader.model_for(:orchestrator)` when `Keyword.get(opts, :model)` returns nil. When an explicit model is passed in opts, it is used as-is. The resolved model is included via the existing `maybe_add/3` helper.

---

## B5: MemoryAgent bare Sentinel pattern match

**Status**: Resolved

**Evidence**:
- `lib/assistant/memory/agent.ex:579-591` — The bare `{:ok, :approved} = Sentinel.check(...)` pattern match has been replaced with a proper `case` expression handling both `{:ok, :approved}` (proceeds to execute) and `{:ok, {:rejected, reason}}` (logs warning, returns rejection message to LLM). The `{:rejected, _}` branch generates a compiler warning about being unreachable because the current Sentinel stub always returns `{:ok, :approved}` — this is expected and correct for Phase 2 readiness.

---

## Summary

| Finding | Status |
|---------|--------|
| B1: SubAgent result capture | Resolved |
| B2: SubAgent missing `:model` | Resolved |
| B3: MemoryAgent missing `:model` | Resolved |
| B4: LoopRunner missing `:model` | Resolved |
| B5: MemoryAgent Sentinel match | Resolved |

All 5 blocking issues from the initial backend review are resolved in commit `88405ae`.
