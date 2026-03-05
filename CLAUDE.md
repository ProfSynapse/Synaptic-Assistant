# Project Memory

This file contains project-specific memory managed by the PACT framework.
The global PACT Orchestrator is loaded from `~/.claude/CLAUDE.md`.

<!-- SESSION_START -->
## Current Session
<!-- Auto-managed by session_init hook. Overwritten each session. -->
- Resume: `claude --resume 21d70a72-99b4-4fde-8cbc-2394ee7e6ad0`
- Team: `pact-21d70a72`
- Started: 2026-03-05 17:48:05 UTC
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
- `HubSpot.Helpers` — hubspot-domain: `parse_properties_json`, `format_object`, `format_object_list`, `resolve_api_key`, `handle_error`, `contact_fields/0`, `company_fields/0`, `deal_fields/0`, `parse_limit/1` (delegates to Skills.Helpers)
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
This applies to `:gmail`, `:calendar`, `:drive`, `:hubspot`. The fallback-to-real-module pattern was removed in Phase 4.

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

### Connection Validation Architecture (PR #29)
Real API handshake validation replaces key-existence checks for integration status.
- **Module**: `IntegrationSettings.ConnectionValidator` — `validate_all/1` runs 7 validators in parallel via `Task.async_stream` (5s timeout, `on_timeout: :kill_task`)
- **Registry pattern**: `@validators` list of `{group, :validate_fn}` tuples — adding integration = 1 tuple + 1 `defp`
- **Tri-state**: `:connected | :not_connected | :not_configured` (UI derives 4th state `:disabled` from toggle)
- **Per-integration**: Telegram `get_me`, Discord `get_gateway`, Slack `auth_test(token)`, Google `user_token(user_id)` / `service_token()`, HubSpot `Client.health_check/1`, ElevenLabs `Client.health_check/1`
- **Admin-gated**: `load_connection_status/1` only runs for `is_admin` users (non-admins get `%{}`)
- **validate_one/2**: Single-integration recheck without full parallel sweep
- **Client modules**: `HubSpot.Client` and `ElevenLabs.Client` with `health_check/1` — configurable base URLs for test mocking
- **Icon states**: connected=green check, disabled=gray X, not_connected=red X, not_configured=gray X (with aria-labels)

### Unified Cross-Channel Conversation Architecture (PR #31)
Single dispatch pipeline for all channels (Telegram, Discord, Slack, Google Chat). Key patterns:
- **Dispatch pipeline**: Webhook → `Dispatcher.dispatch/2` → `UserResolver.resolve/3` → `Engine.send_message/2` → `ReplyRouter.reply/2`
- **UserResolver**: Platform identity → DB user. Uses `user_identities` table for cross-channel identity linking. Config-backed allowlist via `Application.get_env(:assistant, :user_allowlist, :open)`
- **ReplyRouter**: Registry-based channel lookup (NOT `String.to_existing_atom`). Rate limiting via `broadcast_delay_ms` config. Retry with exponential backoff (3 attempts: 100ms, 500ms, 2000ms)
- **CircuitBreaker**: Agent-based per-adapter circuit breaker. States: `:closed` → `:open` (after 5 failures) → `:half_open` (after 30s cooldown). Registered in Application supervision tree
- **ConversationArchiver**: Oban cron worker archiving conversations with `last_active_at` older than 30 days (configurable)
- **Engine input validation**: `byte_size(content) > 200_000` guard (~50K tokens). Configurable timeout via `:engine_call_timeout` (default 300s)
- **Telemetry events**: `[:assistant, :channels, :dispatch, :start|:resolve|:engine|:reply|:error]` + correlation IDs via `Logger.metadata`
- **Conversation schema**: `root_conversation_id/1` recursive with DB fallback for multi-level nesting
- **Migrations**: 3 new — `create_user_identities`, `update_conversations_for_unified` (channel, thread_id, last_active_at), `backfill_user_identities`
- **User schema**: `external_id` and `channel` moved to `@optional_fields` — identity now authoritative in `user_identities`

### HubSpot CRM Connector Architecture (PR #37)
18 skills (6 per object: contacts, companies, deals) with CRUD + search + list_recent. Key patterns:
- **Auth**: Single org-wide Bearer token via `IntegrationSettings.get(:hubspot_api_key)` — resolved in each handler (NOT context builder). No per-user OAuth.
- **Client DRY pattern**: Generic `crm_create/3`, `crm_get/4`, `crm_update/4`, `crm_delete/3`, `crm_search/7`, `crm_list/5` private functions — all 3 CRM types share identical REST patterns (`/crm/v3/objects/{type}`)
- **Registry**: `:hubspot => HubSpot.Client` in `Integrations.Registry.default_integrations/0`
- **ID validation**: All get/update/delete handlers validate `String.match?(id, ~r/^\d+$/)` before API call
- **Pagination**: `crm_list/5` accepts optional `after` cursor; returns `%{results: [...], next: cursor_or_nil}`
- **Retry**: `retry: :transient`, `max_retries: 3`, `retry_delay: 500 * attempt` on all CRM operations (NOT health_check)
- **Multi-filter search**: `crm_search_multi/5` accepts list of `{property, operator, value}` tuples (AND logic); simple `query+search_by` still works
- **Confirm gate**: `confirm: true` on all mutating skill definitions (create, update, delete)
- **Configurable base_url**: `Application.get_env(:assistant, :hubspot_api_base_url)` for Bypass test mocking

### Admin-Only Model Management + LLM Router (PR #45)
Credential-based LLM routing and admin-only model/skill management. Key patterns:
- **LLMRouter.route/2**: 3-tier priority: (1) user OpenRouter key → OpenRouter, (2) user OpenAI creds → Direct OpenAI (strip `openai/` prefix), (3) neither → OpenRouter with nil api_key (client falls back to system key). No guessing/parsing — credentials are source of truth.
- **ModelDefaults admin-only**: `mode/1` returns `:global` for admins, `:readonly` for all others. `:personal` mode removed entirely. `save_defaults/2` guards on `is_admin: true`.
- **Fallback model cascade**: `ConfigLoader.resolve_fast_model/2` shared helper — tries role-specific → compaction → `:model_default_fallback` (registry) → `models_by_tier(:fast)`. Used by sentinel + turn_classifier.
- **3-layer skill permissions**: `SkillPermissions.enabled_for_user?/2` — `global_enabled AND user_enabled AND connector_enabled`. Admin gate on `toggle_skill_permission` LiveView event.
- **Per-user connectors**: `settings_user_connector_states` table (FK to settings_users) + `user_skill_overrides` table. Upsert pattern with unique indexes.
- **Elixir 1.19 gotcha**: Schema modules need `@type t :: %__MODULE__{}` or compilation fails with `type t/0 undefined`.

### Phase Status
- Phase 1-4 complete and merged (PR #9). Branch: `main`.
- Phase 4 covers: Gmail (5 skills), Calendar (3 skills), Workflow scheduler (4 skills + WorkflowWorker + QuantumLoader).
- Phase 5 (PR #11): Per-user Google OAuth2 with magic link authorization flow.
- Phase 6 (PR #15): Scoped Drive access + OAuth2 improvements (race fix, revocation, encrypted code_verifier, cleanup worker).
- Phase 7 (PR #19): OpenRouter PKCE OAuth connect button + per-user key threading.
- Phase 12 (PR #29): Connection validation — real API handshakes for integration status.
- PR #31: Unified cross-channel conversation architecture (UserResolver, Dispatcher, ReplyRouter, CircuitBreaker, ConversationArchiver).
- PR #32: Cross-channel OAuth key resolution fix — CrossChannelBridge module, ensure_linked_user dedup, data repair migration.
- PR #37: HubSpot CRM connector — 18 skills (contacts, companies, deals) with pagination, retry, multi-filter search.
- PR #45: Admin-only model management, credential-based LLM routing, fallback model cascade, 3-layer skill permissions, per-user connector states.
