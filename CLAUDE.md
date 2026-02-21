# Project Memory

This file contains project-specific memory managed by the PACT framework.
The global PACT Orchestrator is loaded from `~/.claude/CLAUDE.md`.

<!-- SESSION_START -->
## Current Session
<!-- Auto-managed by session_init hook. Overwritten each session. -->
- Resume: `claude --resume 174f7e2a-5972-4e16-a3cd-4490ca9de13b`
- Team: `pact-174f7e2a`
- Started: 2026-02-21 14:52:20 UTC
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

### OpenRouter OAuth Architecture (PR #19)
Settings-user-level PKCE OAuth connect flow. Key patterns:
- **Storage**: `settings_users.openrouter_api_key` (encrypted `Encrypted.Binary`) — NOT `oauth_tokens` (avoids chat user_id dependency)
- **Flow**: `/settings_users/auth/openrouter` → OpenRouter PKCE consent → `/callback` → POST `https://openrouter.ai/api/v1/auth/keys` → permanent `sk-or-v1-...` key stored
- **Zero-config**: No server API key needed — code exchange sends `code_verifier` + `code_challenge_method: "S256"` in body with no Authorization header; works out of the box for self-hosters
- **No refresh tokens, no revocation endpoint** — disconnect = `delete_openrouter_api_key/1` (DB only)
- **Per-user key threading**: `Accounts.openrouter_key_for_user(user_id)` bridges `users.id` → `settings_users.openrouter_api_key`; all LLM callers pass `api_key:` opt; falls back to system key when nil (unlike Google which rejects)
- **Controller**: `OpenRouterOAuthController` — `request/2` + `callback/2` only; disconnect handled by LiveView `phx-click="disconnect_openrouter"`
- **Configurable keys URL**: `Application.get_env(:assistant, :openrouter_keys_url, "https://openrouter.ai/api/v1/auth/keys")` — needed for Bypass in tests

### Phase Status
- Phase 1-4 complete and merged (PR #9). Branch: `main`.
- Phase 4 covers: Gmail (5 skills), Calendar (3 skills), Workflow scheduler (4 skills + WorkflowWorker + QuantumLoader).
- Phase 5 (PR #11): Per-user Google OAuth2 with magic link authorization flow.
- Phase 6 (PR #15): Scoped Drive access + OAuth2 improvements (race fix, revocation, encrypted code_verifier, cleanup worker).
- Phase 7 (PR #19): OpenRouter PKCE OAuth connect button + per-user key threading.
