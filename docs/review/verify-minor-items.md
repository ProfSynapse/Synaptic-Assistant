# Verify Minor Items M1-M8 + F3

**Commits verified**: 0510da2 (backend coder, M1-M8), 53820dc (test engineer, M5 + F3 tests)

| Item | Status | Notes |
|------|--------|-------|
| M1 | Resolved | `TurnClassifier.dispatch_to_memory_agent/3` sends a single `GenServer.cast(pid, {:mission, mission, params})`. The `save_facts` branch dispatches `:save_and_extract` (one combined cast), not two sequential `:save_memory` + `:extract_entities` casts. See `turn_classifier.ex:128` and `turn_classifier.ex:188-197`. |
| M2 | Resolved | `Limits.check_conversation/2` (L4 circuit breaker) is called at the top of `run_loop/1` in `engine.ex:241`, before `run_loop_iteration` which makes the LLM call. On `:limit_exceeded`, the loop returns a user-facing message without calling the LLM. |
| M3 | Resolved | Both `sub_agent.ex:536` and `agent.ex:530` have `after 300_000` (5 minutes) receive timeouts in their `request_help` pause blocks. Both log a warning and return a `:failed` status map on timeout. |
| M4 | Resolved | `TurnClassifier` uses `@llm_client Application.compile_env(:assistant, :llm_client, Assistant.Integrations.OpenRouter)` at `turn_classifier.ex:39-43`. No hardcoded OpenRouter reference in the runtime call path -- `@llm_client.chat_completion(...)` at line 108. |
| M5 | Resolved | `prompt_loader_test.exs` passes all required assigns: `skill_domains`, `user_id`, `current_date` in the main render test (line 79-83), and explicit empty-string assigns in the missing-variables test (line 99). The test YAML template at line 13-17 uses all three variables, matching the assigns. |
| M6 | Resolved | `notification_channel.ex:18` has `# TODO: encrypt with Cloak.Ecto before storing real credentials` comment directly above the `:config` field. The `@moduledoc` at line 3-5 also documents "Cloak.Ecto encryption is planned but not yet wired." |
| M7 | Resolved | `llm_helpers.ex` exists at `lib/assistant/orchestrator/llm_helpers.ex` with shared functions: `resolve_model/1`, `build_llm_opts/2`, `text_response?/1`, `tool_call_response?/1`, `extract_function_name/1`, `extract_function_args/1`, `extract_last_assistant_text/1`. Delegation confirmed in: `sub_agent.ex:1181-1185` (5 delegate wrappers), `agent.ex:927-932` (5 delegate wrappers), `loop_runner.ex:76,80,122-123,161-162` (uses LLMHelpers directly). |
| M8 | Resolved | `context.ex:253-267` (`trim_messages_by_estimation`) calls `group_into_turns/1` to group messages into turns (user + subsequent assistant/tool messages) before trimming. `context.ex:322-342` implements `group_into_turns/1`: starts a new group at each "user" role, keeping assistant/tool messages with their preceding user message. Trimming drops whole turns atomically (lines 257-265 iterate over turns, not individual messages). The usage-based path (`trim_messages_by_usage` at line 272) delegates to `trim_oldest/2` at line 303 which also uses `group_into_turns`. |
| F3 | Resolved | 64 new test cases across 6 files: `openrouter_test.exs` (19), `loop_runner_test.exs` (7), `dispatch_agent_test.exs` (7), `get_agent_results_test.exs` (18), `get_skill_test.exs` (7), `send_agent_update_test.exs` (6). Tests cover tool definitions, validation error paths, edge cases (empty inputs, unknown agents/skills, mixed states), wait modes, transcript tails, and format helpers. |

**Summary**: All 9 items verified as resolved. No new issues detected.
