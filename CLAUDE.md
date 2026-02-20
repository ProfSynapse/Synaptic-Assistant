# Project Memory

This file contains project-specific memory managed by the PACT framework.
The global PACT Orchestrator is loaded from `~/.claude/CLAUDE.md`.

<!-- SESSION_START -->
## Current Session
<!-- Auto-managed by session_init hook. Overwritten each session. -->
- Resume: `claude --resume 50ba7086-b2ce-4063-a7d9-f9685c033d4f`
- Team: `pact-50ba7086`
- Started: 2026-02-20 17:34:09 UTC
<!-- SESSION_END -->

## Retrieved Context
<!-- Auto-managed by pact-memory skill. Last 3 retrieved memories shown. -->

## Working Memory
<!-- Auto-managed by pact-memory skill. Last 3 memories shown. Full history searchable via pact-memory skill. -->

## Pinned Architecture

### Shared Helpers Pattern (Phase 4)
All helper extraction follows this hierarchy — do NOT re-duplicate functions:
- `Skills.Helpers` — cross-domain: `parse_limit/3` (value, default, max)
- `Email.Helpers` — email-domain: `has_newlines?`, `truncate_log`, `truncate`, `full_mode?`, `parse_limit/1` (delegates to Skills.Helpers)
- `Calendar.Helpers` — calendar-domain: `normalize_datetime`, `parse_attendees`, `maybe_put`, `parse_limit/1` (delegates to Skills.Helpers)
- `Workflow.Helpers` — workflow-domain: `resolve_workflows_dir/0`
- All helper modules use `@moduledoc false`

### Integration Injection Pattern
**Always use nil-check pattern** — never fall back to real module:
```elixir
case Map.get(context.integrations, :gmail) do
  nil -> {:ok, %Result{status: :error, content: "Gmail integration not configured."}}
  gmail -> ...
end
```
This applies to `:gmail`, `:calendar`, `:drive`. The fallback-to-real-module pattern was removed in Phase 4.

### Workflow File Security
All workflow skills that take a `name` flag must validate with `~r/^[a-z][a-z0-9_-]*$/` before path construction. `WorkflowWorker.resolve_path/1` rejects absolute paths, `../` traversal, and symlinks as a safety net — but callers must also validate.

### YAML Frontmatter Safety
`workflow/create.ex` validates user-controlled fields with `validate_field/2`: rejects embedded newlines (`\n`, `\r`) and double-quotes (`"`). Apply same pattern to any new skill that writes YAML files.

### Google OAuth2 + Drive Scoping Architecture (PR #11 + PR #15)
Per-user OAuth2 and scoped Drive access merged to main. Key patterns:
- **Dual-mode auth**: `Auth.service_token/0` (Chat bot, Goth service account) vs `Auth.user_token/1` (per-user, with per-user mutex via `:global.trans` — double-checked locking to prevent concurrent refresh race)
- **Lazy auth**: skill invoked → no token → `maybe_require_google_auth/3` in `sub_agent.ex` → magic link sent → `PendingIntentWorker` auto-replays original command after OAuth
- **Token errors**: `:not_connected` (never authed), `:token_expired` (needs refresh), `:refresh_failed` (grant revoked)
- **Schema location**: `lib/assistant/schemas/OAuthToken` + `AuthToken` (NOT `lib/assistant/accounts/`)
- **PKCE + code_verifier**: stored encrypted (`Encrypted.Binary`) in `auth_tokens`; ETS removed entirely
- **Oban queues**: `:oauth_replay` for `PendingIntentWorker`; `AuthTokenCleanupWorker` cron daily 03:00 UTC
- **Test env vars required**: `ENV_VAR=placeholder ELEVENLABS_VOICE_ID=test-voice-id CLOAK_ENCRYPTION_KEY="Q5UmN+2rIM+Fpep+9KYgyKHKNMLuj9vwL2plpp+ADko="`
- **Drive/Gmail/Calendar**: all public functions accept `access_token` as first param; `context.google_token` threaded through all skill files
- **Token revocation**: `OAuth.revoke_token/1` called on disconnect (POST to `https://oauth2.googleapis.com/revoke`)

### Drive Scoping Architecture (PR #15)
Users select which Google Drives the agent can access (personal My Drive + shared drives).
- **Schema**: `connected_drives` table — `drive_type` (:personal/:shared), `drive_id` (nil for My Drive), `enabled` boolean
- **Partial unique indexes**: `(user_id) WHERE drive_id IS NULL` for personal; `(user_id, drive_id) WHERE drive_id IS NOT NULL` for shared
- **Upsert pattern**: `{:unsafe_fragment, "..."}` for conflict_target on partial indexes
- **Drive.Scoping**: `build_query_params/1` returns `[keyword()]` (list, one per enabled drive) — NOT a single `allDrives` corpora
  - Personal only → `[[corpora: "user"]]`
  - Shared drive → `[[corpora: "drive", driveId: id, supportsAllDrives: true, includeItemsFromAllDrives: true]]`
  - `search.ex` fans out one API call per scope; `archive.ex` searches scopes sequentially
- **Context threading**: `enabled_drives` injected into skill context from `ConnectedDrives.enabled_for_user/1`
- **Shared GoogleContext module**: `lib/assistant/orchestrator/google_context.ex` — shared helpers for loop_runner + sub_agent

### settings_users vs users Bridge
Two separate tables: `settings_users` (web dashboard login) and `users` (chat users).
- Bridge via nullable `user_id` FK on `settings_users` (migration 20260220140000)
- Auto-linked in `OAuthController` callback via email match: `maybe_link_settings_user/2`
- **Always use `settings_user.user_id`** (not `settings_user.id`) when calling TokenStore, ConnectedDrives

### Async Background Memory Save Hook (PR #16)
After every sub-agent completes, `engine.ex` enqueues `MemorySaveWorker` (fire-and-forget) to save the full agent transcript to memory. Critical patterns:
- **NEVER use `start_link` in sub_agent.ex** — must be `GenServer.start`. EXIT signal from shutdown propagates to the linked caller Task and kills it before `wait_for_completion/2` reads the `:DOWN` message. Comment in code explains this.
- **`source_type: "agent_result"`** is valid in `memory_entry.ex` — added in PR #16. The `@source_types` enum and DB CHECK constraint both include it.
- **Transcript cap**: 50KB max before Oban enqueue (`@max_transcript_bytes 50_000` in engine.ex)
- **Oban queue**: `:memory` (5 workers, no uniqueness constraint — intentionally removed)

### Orchestrator Model Benchmark (PR #16)
Benchmark at `/tmp/orchestrator_bench.exs` — run with `set -a && source .env && set +a && mix run /tmp/orchestrator_bench.exs -- --models model1,model2`
- **Best orchestrator**: `google/gemini-3.1-pro-preview` — 20/20 (100%), only model that uses `depends_on` upfront
- haiku-4.5 = sonnet-4.6 = 70%; gpt-5-mini = 65%; gpt-5.2 = 60%
- Multi-dispatch failures in haiku/sonnet are architectural (sequential dispatch by design), not prompt issues

### Integration Test Suite (PR #16)
`test/integration/` — real LLM API calls + mocked external services. 30 tests across 7 skill domains.
- Run: `TEST_MODEL=anthropic/claude-haiku-4.5 mix test test/integration/ --include integration`
- Excluded from default `mix test` — already configured in test_helper.exs

### Phase Status
- Phase 1-4 complete and merged (PR #9). Branch: `main`.
- Phase 4 covers: Gmail (5 skills), Calendar (3 skills), Workflow scheduler (4 skills + WorkflowWorker + QuantumLoader).
- Phase 5 (PR #11): Per-user Google OAuth2 with magic link authorization flow.
- Phase 6 (PR #15): Scoped Drive access + OAuth2 improvements (race fix, revocation, encrypted code_verifier, cleanup worker).
- Phase 7 (PR #16): Orchestrator prompt rewrite, async memory save hook, integration test suite.
