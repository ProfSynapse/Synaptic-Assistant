# Backend Implementation Review — PR #1: Phase 1 Foundation

**Reviewer**: Backend Coder (Elixir/OTP Implementation Quality)
**Date**: 2026-02-18
**Scope**: Engine, OpenRouter, SubAgent, MemoryAgent, Context, Nudger, Config, Skills, Resilience

---

## Summary

The Phase 1 backend implementation is solid and well-structured. The codebase demonstrates strong OTP patterns, clean separation of concerns between pure-function modules and stateful GenServers, and thoughtful error handling throughout. The architecture is cache-aware from the ground up, and resource limits are enforced at four levels with a consistent return-type convention.

**Strengths**:
- Clean Engine/LoopRunner separation (stateful GenServer vs pure functions)
- ETS-backed config and skill registry for lock-free concurrent reads
- Four-level circuit breaker hierarchy with consistent API (`{:ok, state}` / `{:error, :limit_exceeded, details}`)
- Context trimming with usage-based + estimation fallback is a strong design
- Nudger zero-code-change extensibility pattern (YAML-driven hints)
- Comprehensive documentation with file-header cross-references

**Areas requiring attention**: 5 Blocking, 9 Minor, 4 Future items identified below.

---

## Blocking Issues

### B1. SubAgent `wait_for_completion` cannot retrieve result after normal exit

**File**: `lib/assistant/orchestrator/sub_agent.ex:1046-1074`

When the GenServer exits with `{:stop, :normal, state}` (line 371), the process is dead before `wait_for_completion` calls `get_status/1` (line 1049). The `get_status` call will always fail with `:not_found` because the process has terminated, falling through to `fetch_from_registry_or_default/1` which returns a generic "status unavailable" message. The actual result stored in the GenServer's final state is lost.

**Impact**: Every synchronous `execute/3` call loses the sub-agent's actual result text. The Engine receives "Agent completed (status unavailable after shutdown)." instead of the real output.

**Fix**: Store the final result in a persistent location before the GenServer stops. Options: (a) use an ETS table keyed by agent_id to stash the result in `handle_info({ref, result}, ...)` before stopping, (b) have the GenServer `reply` to the caller directly rather than relying on a post-mortem `get_status` call, or (c) use the `{:shutdown, result}` exit reason to pass data through the `:DOWN` message.

---

### B2. SubAgent `build_model_opts` does not include `:model` when no override is set

**File**: `lib/assistant/orchestrator/sub_agent.ex:1116-1123`

```elixir
defp build_model_opts(dispatch_params, context) do
  opts = [tools: context.tools]
  case dispatch_params[:model_override] do
    nil -> opts       # <-- No :model key!
    model -> Keyword.put(opts, :model, model)
  end
end
```

When `model_override` is nil (the common case), the opts list contains only `:tools` with no `:model` key. The OpenRouter client requires `:model` and returns `{:error, :no_model_specified}` when it is missing (line 224). This means every sub-agent LLM call without an explicit model override will fail.

**Impact**: Sub-agents without `model_override` cannot make LLM calls. This is likely masked in tests by mock LLM clients.

**Fix**: Add a default model resolution:
```elixir
nil ->
  model = Loader.model_for(:sub_agent)
  if model, do: Keyword.put(opts, :model, model.id), else: opts
```

---

### B3. MemoryAgent `build_model_opts` has the same missing `:model` issue

**File**: `lib/assistant/memory/agent.ex:838-840`

```elixir
defp build_model_opts(context) do
  [tools: context.tools]
end
```

No `:model` key is ever set. Same problem as B2 -- every MemoryAgent LLM call will fail with `{:error, :no_model_specified}`.

**Impact**: MemoryAgent missions cannot execute LLM calls.

**Fix**: Resolve the model from config:
```elixir
defp build_model_opts(context) do
  model = Loader.model_for(:sub_agent)
  opts = [tools: context.tools]
  if model, do: Keyword.put(opts, :model, model.id), else: opts
end
```

---

### B4. LoopRunner `run_iteration` does not resolve `:model` from config when caller omits it

**File**: `lib/assistant/orchestrator/loop_runner.ex:70-89`

```elixir
def run_iteration(messages, loop_state, opts \\ []) do
  tools = Keyword.get(opts, :tools, Context.tool_definitions())
  model = Keyword.get(opts, :model)   # nil if not passed
  llm_opts = [tools: tools] |> maybe_add(:model, model)
  # ...
end
```

The Engine calls `run_iteration/3` with `opts = [tools: context.tools]` (engine.ex:247), never including `:model`. So `model` is nil, `maybe_add` skips it, and OpenRouter receives no model. Same failure as B2/B3.

**Impact**: The orchestrator's LLM calls fail unless something else sets the model. This is the first LLM call in the entire system (orchestrator loop), so the whole assistant is broken without a model.

**Fix**: LoopRunner or Engine should resolve the model from `ConfigLoader.model_for(:orchestrator)` and include it in the opts.

---

### B5. MemoryAgent Sentinel check uses pattern match that crashes on rejection

**File**: `lib/assistant/memory/agent.ex:580`

```elixir
{:ok, :approved} = Sentinel.check(original_request, "memory management", proposed_action)
```

This is a bare pattern match that will crash (MatchError) if Sentinel ever returns `{:ok, {:rejected, reason}}`. While Sentinel is currently a stub that always approves, this is explicitly documented as a Phase 2 change point. When Phase 2 activates rejection logic, the MemoryAgent will crash on any rejected action.

The SubAgent (`sub_agent.ex:583-594`) correctly handles both `:approved` and `{:rejected, reason}` with a case statement. MemoryAgent should follow the same pattern.

**Impact**: Phase 2 Sentinel activation will crash MemoryAgent processes on any rejection.

**Fix**: Change to a case statement matching both outcomes, as SubAgent does.

---

## Minor Issues

### M1. Engine `handle_call(:send_message, ...)` runs synchronously — blocks GenServer for entire LLM loop

**File**: `lib/assistant/orchestrator/engine.ex:160-192`

The `send_message` handler runs `run_loop(state)` synchronously inside `handle_call`. This blocks the Engine GenServer for the entire duration of the LLM loop, which can include multiple LLM round-trips and sub-agent executions. During this time, `get_state` calls and any other messages are queued.

While the 120-second `GenServer.call` timeout (line 102) provides a cap, this is a known design choice worth documenting. The Engine process is per-conversation, so cross-conversation blocking doesn't occur. However, it means no monitoring or status queries can be served during a turn.

**Recommendation**: Add a comment noting this is intentional for Phase 1. Consider async processing with `{:noreply, state}` + caller notification in a future phase.

---

### M2. Engine `terminate/2` calls `Supervisor.stop` but `agent_supervisor` is a `Task.Supervisor`

**File**: `lib/assistant/orchestrator/engine.ex:218-219`

```elixir
if Process.alive?(state.agent_supervisor) do
  Supervisor.stop(state.agent_supervisor, :shutdown, 5_000)
end
```

The `agent_supervisor` is started via `Task.Supervisor.start_link` (line 125), which creates an unlinked process. Since it's started inside `init/1` without being linked to the Engine, if the Engine crashes, the Task.Supervisor process leaks. The `terminate/2` cleanup only runs on graceful shutdown, not on crashes.

**Recommendation**: Link the Task.Supervisor to the Engine process, or start it under the Engine's supervision. Alternatively, add it as a child of the ConversationSupervisor.

---

### M3. TurnClassifier dispatches both `save_memory` and `extract_entities` sequentially to the same MemoryAgent

**File**: `lib/assistant/memory/turn_classifier.ex:123-138`

When classified as `save_facts`, TurnClassifier dispatches `:save_memory` and then immediately `:extract_entities` to the same MemoryAgent. Since MemoryAgent is a single GenServer and the second mission will hit the `handle_cast({:mission, ...}, state)` busy clause (agent.ex:313), the second mission is silently dropped.

**Impact**: `extract_entities` missions from save_facts classification are always dropped because the agent is busy processing `save_memory`.

**Recommendation**: Either combine save_memory + extract_entities into a single mission, or implement a mission queue in MemoryAgent so queued missions execute after the current one completes.

---

### M4. Config.Loader `parse_defaults` uses `String.to_atom/1` on untrusted YAML input

**File**: `lib/assistant/config/loader.ex:271-278`

```elixir
defp parse_defaults(defaults) when is_map(defaults) do
  atomized = Map.new(defaults, fn {key, value} ->
    {String.to_atom(key), String.to_atom(value)}
  end)
  {:ok, atomized}
end
```

`String.to_atom/1` on arbitrary user-controlled strings creates atoms that are never garbage collected. While config.yaml is an internal file (not user-facing input), this is a pattern risk. Similar usage exists in `parse_models` (line 288-289) and `PromptLoader.load_prompt_file` (line 194).

**Recommendation**: Use `String.to_existing_atom/1` with a rescue, or maintain an allowlist of valid atoms. Low risk for internal config, but worth addressing if config ever becomes user-editable.

---

### M5. PromptLoader `render_template` uses `Code.eval_quoted` which is powerful but has side-effect risk

**File**: `lib/assistant/config/prompt_loader.ex:269-279`

```elixir
defp render_template(compiled_template, assigns) do
  try do
    binding = Enum.map(assigns, fn {k, v} -> {to_atom(k), v} end)
    {result, _binding} = Code.eval_quoted(compiled_template, assigns: binding)
    {:ok, result}
  rescue
    e -> {:error, {:render_failed, Exception.message(e)}}
  end
end
```

`Code.eval_quoted` with pre-compiled EEx templates is correct and the standard pattern. However, if a malicious template contained executable Elixir code (e.g., `<%= System.cmd("rm", ["-rf", "/"]) %>`), it would execute. Since templates are loaded from the project's own `config/prompts/` directory, this is acceptable, but a comment noting this trust boundary would be helpful.

**Recommendation**: Add a comment documenting that prompt templates are trusted (project-controlled files).

---

### M6. Context trimming `trim_oldest` may remove system/tool messages in the middle of a tool-call sequence

**File**: `lib/assistant/orchestrator/context.ex:297-312`

The `trim_oldest` function removes messages from the front of the list without regard to message role. If trimming cuts into a tool-call exchange (assistant tool_calls message removed but tool result kept, or vice versa), the LLM will receive malformed message history.

**Recommendation**: Ensure trimming respects message boundaries — never separate a tool_calls message from its tool result messages. Either trim in atomic groups (assistant+tool_results as a unit) or insert a summary marker.

---

### M7. SubAgent `receive` block in `execute_tool_calls` has no timeout

**File**: `lib/assistant/orchestrator/sub_agent.ex:502-523`

```elixir
receive do
  {:resume, update} ->
    # ...
end
```

If the orchestrator never sends a `:resume` message (e.g., orchestrator crashes, network partition, user abandons), the Task running the LLM loop will block forever. The Task.async owner (GenServer) would need to be manually shut down.

**Recommendation**: Add an `after` timeout clause (e.g., 5 minutes) that returns a timeout result. Same applies to MemoryAgent at agent.ex:507-520.

---

### M8. Duplicated helper functions across SubAgent and MemoryAgent

**Files**: `lib/assistant/orchestrator/sub_agent.ex:1133-1178` and `lib/assistant/memory/agent.ex:887-920`

The following functions are copy-pasted between SubAgent and MemoryAgent:
- `has_text_no_tools?/1`
- `has_tool_calls?/1`
- `extract_function_name/1` (4 clauses)
- `extract_function_args/1` (5 clauses)
- `extract_last_text/1` / `extract_last_assistant_text/1`

Also duplicated in `loop_runner.ex:118-260`.

**Recommendation**: Extract these into a shared helper module (e.g., `Assistant.Orchestrator.ResponseParser` or `Assistant.LLM.ResponseHelpers`). This reduces maintenance burden and ensures consistent behavior.

---

### M9. Application supervision tree hardcodes `user_id: "dev-user"` for MemoryAgent

**File**: `lib/assistant/application.ex:40`

```elixir
{Assistant.Memory.Agent, user_id: "dev-user"},
```

This creates exactly one MemoryAgent process for a hardcoded user. In production, memory agents should be dynamically started per-user. The hardcoded ID means all users share one memory agent (or only the dev user gets one).

**Recommendation**: Acceptable for Phase 1/dev, but flag as a Phase 2 item: move MemoryAgent startup to a DynamicSupervisor and start/stop agents as users connect.

---

## Future Improvements

### F1. Conversation-level circuit breaker (Level 4) is initialized but never checked in Engine

**File**: `lib/assistant/orchestrator/engine.ex:136`

The Engine initializes `conversation_state: CircuitBreaker.new_conversation_state()` but never calls `CircuitBreaker.check_conversation/2` or `Limits.check_conversation/2` anywhere in the loop. Level 4 is effectively dead code.

**Recommendation**: Wire Level 4 checks into the Engine loop, or document that it's deferred to Phase 2.

---

### F2. ExecutionLog records created in dispatch_agent are never updated to "completed"/"failed"

**File**: `lib/assistant/orchestrator/tools/dispatch_agent.ex:266-287`

The dispatch creates an ExecutionLog with `status: "pending"` but there is no code path that updates it to "completed" or "failed" after the sub-agent finishes. The execution_log_id is carried in dispatch_params but never used by the Engine or SubAgent for status updates.

**Recommendation**: Add execution log updates in the Engine's result handling (after AgentScheduler returns results).

---

### F3. OpenRouter streaming `Process.put`/`Process.delete` pattern for usage accumulation

**File**: `lib/assistant/integrations/openrouter.ex:166-186`

Using process dictionary for stream usage accumulation works because `into:` callbacks run in the same process as `Req.post/2`. This is correct, but the pattern is fragile if Req ever changes its callback threading model.

**Recommendation**: Consider using an Agent or accumulator pattern in a future refactor. Low risk currently.

---

### F4. Config.Loader `interpolate_env_vars` uses throw/catch for control flow

**File**: `lib/assistant/config/loader.ex:237-250`

Using `throw` + `catch` for early return from `Regex.replace/3` is a pragmatic approach, but non-idiomatic Elixir. It works correctly and is confined to this one function.

**Recommendation**: Consider a two-pass approach (scan for missing vars, then replace) in a future cleanup. Not urgent.

---

## Code Quality Assessment

| Dimension | Rating | Notes |
|-----------|--------|-------|
| **Correctness** | 7/10 | B1-B4 represent real bugs that would prevent LLM calls. Otherwise solid. |
| **Error Handling** | 8/10 | Comprehensive error tuples, fallback prompts, graceful degradation. B5 is a landmine. |
| **Performance** | 9/10 | ETS for reads, cache-aware context assembly, usage-based trimming, minimal allocations. |
| **Security** | 7/10 | Sentinel stub acknowledged. M4 atom creation from config. M5 eval_quoted on trusted files. |
| **Maintainability** | 8/10 | Good separation of concerns. M8 duplication is the main debt. Excellent docs. |
| **OTP Patterns** | 8/10 | Clean GenServer usage. M2 (unlinked supervisor) and M7 (infinite receive) are gaps. |

---

## Files Reviewed

| File | Lines | Verdict |
|------|-------|---------|
| `lib/assistant/orchestrator/engine.ex` | 555 | Good with M1, M2, F1 |
| `lib/assistant/integrations/openrouter.ex` | 595 | Clean, well-documented (F3) |
| `lib/assistant/orchestrator/sub_agent.ex` | 1179 | B1, B2, M7, M8 — over 500 lines |
| `lib/assistant/memory/agent.ex` | 921 | B3, B5, M3, M8 — over 500 lines |
| `lib/assistant/orchestrator/context.ex` | 344 | Good with M6 |
| `lib/assistant/orchestrator/nudger.ex` | 196 | Clean, well-designed |
| `lib/assistant/config/loader.ex` | 384 | Good with M4 |
| `lib/assistant/config/prompt_loader.ex` | 283 | Good with M5 |
| `lib/assistant/skills/executor.ex` | 108 | Clean |
| `lib/assistant/orchestrator/loop_runner.ex` | 273 | B4, M8 |
| `lib/assistant/orchestrator/agent_scheduler.ex` | 431 | Clean, well-structured DAG |
| `lib/assistant/memory/context_monitor.ex` | 117 | Clean |
| `lib/assistant/memory/turn_classifier.ex` | 224 | M3 |
| `lib/assistant/memory/skill_executor.ex` | 196 | Clean, good search-first design |
| `lib/assistant/resilience/circuit_breaker.ex` | 378 | Clean, well-documented |
| `lib/assistant/orchestrator/limits.ex` | 212 | Clean (thin facade) |
| `lib/assistant/skills/registry.ex` | 258 | Clean |
| `lib/assistant/orchestrator/tools/dispatch_agent.ex` | 304 | F2 |
| `lib/assistant/orchestrator/sentinel.ex` | 94 | Clean stub |
| `lib/assistant/application.ex` | 61 | M9 |
