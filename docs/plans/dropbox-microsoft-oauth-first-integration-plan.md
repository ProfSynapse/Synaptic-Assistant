# Implementation Plan: Dropbox + Microsoft OAuth-First Workspace Integrations

> Created: 2026-03-04
> Status: PROPOSED
> Direction: Add Dropbox and Microsoft integrations using the same per-user OAuth-first pattern as Google, with no per-user API keys.

## Summary

This plan extends the existing Google-style integration architecture to:

1. Connect Dropbox via per-user OAuth (offline refresh tokens, PKCE, magic-link initiation).
2. Connect Microsoft via per-user OAuth to Microsoft Graph for:
   - OneDrive / SharePoint files
   - Outlook mail
   - Outlook calendar
   - Optional Teams messaging (phase-gated)
3. Reuse current patterns already proven in this codebase:
   - `auth_tokens` magic-link + PKCE flow
   - encrypted `oauth_tokens` storage
   - `SettingsLive` connect/disconnect UX
   - `Req` as the HTTP client
   - lazy auth + replay via `PendingIntentWorker`

No per-user API keys are required.  
One-time app registration credentials are still required per provider (client ID + redirect URI + secret/cert for web apps).

---

## Specialist Perspectives

### 📋 Preparation Phase
**Effort**: Medium

#### Research Needed
- [x] Dropbox OAuth code flow with PKCE and offline refresh tokens
- [x] Dropbox webhook verification model (`X-Dropbox-Signature`) and challenge handshake
- [x] Microsoft Entra OAuth code flow (v2) + PKCE + `offline_access`
- [x] Microsoft Graph Files / Mail / Calendar endpoint and permission mapping
- [x] Microsoft Graph change notifications + validation token handshake
- [x] Microsoft Graph delta query model for file/mail/calendar sync

#### Hard Constraints
- Use `Req` for all HTTP calls (project standard).
- Preserve encrypted token-at-rest behavior via Cloak (`Assistant.Encrypted.Binary`).
- Preserve router/auth patterns from `phx.gen.auth` and current OAuth routes.
- OAuth-first UX from Settings must continue to work with popup-based connect.

#### Important Product Clarification
- "OAuth-first, no API keys" is achievable for end users.
- Admin still needs to configure OAuth app credentials per provider:
  - Dropbox app key (+ secret for confidential web app)
  - Microsoft app registration client ID (+ client secret or certificate for web app)

---

### 🏗️ Architecture Phase
**Effort**: High

#### Baseline Patterns to Reuse

| Existing pattern | Current implementation | Reuse for Dropbox/Microsoft |
|---|---|---|
| Magic link + PKCE OAuth bootstrapping | `Assistant.Auth.MagicLink`, `AssistantWeb.OAuthController` | Extend to provider-aware flow |
| Encrypted per-user token storage | `oauth_tokens`, `Assistant.Auth.TokenStore` | Add provider support + provider-specific helpers |
| Connect/disconnect from settings | `SettingsLive.Events` (`connect_google`, `disconnect_google`) | Add `connect_dropbox`, `connect_microsoft`, disconnect peers |
| App configuration in admin UI | `IntegrationSettings.Registry` + app catalog | Add Dropbox/Microsoft key groups and app cards |
| Skill context integration module registry | `Assistant.Integrations.Registry.default_integrations/0` | Add Dropbox and Microsoft integration clients |
| Lazy auth in orchestration | `maybe_require_google_auth/3` in `SubAgent` | Generalize to provider-aware lazy auth |

#### Major Architecture Decisions

| Decision | Options | Recommendation | Rationale |
|---|---|---|---|
| OAuth module shape | One giant generic module vs provider modules | Provider modules + shared helpers | Keeps provider semantics clear and testable |
| OAuth callback controllers | Single dynamic provider controller vs per-provider | Per-provider controllers first | Lowest migration risk; matches current style |
| Skill provider routing | New skill namespaces vs optional `--provider` | Keep existing skills + add `--provider` | Preserves prompt/tool stability and existing skill names |
| Token storage schema | New tables per provider vs extend `oauth_tokens` | Extend existing `oauth_tokens` providers | Existing table already designed for multi-provider |
| Microsoft ecosystem scope breadth | One huge initial scope set vs phased scopes | Phase core scopes, gate Teams scopes | Reduces consent friction and enterprise risk |
| Remote sync parity | Immediate parity with Google sync engine vs phased | Phase after core CRUD skills | Faster first value, lower blast radius |

---

### 💻 Code Phase
**Effort**: High

## OAuth and Router Design

### Route placement (explicitly matching existing auth patterns)

1. **Provider OAuth start/callback routes**
- Scope: `scope "/auth", AssistantWeb`
- Pipeline: `:oauth_browser`
- Routes:
  - `GET /auth/dropbox/start`
  - `GET /auth/dropbox/callback`
  - `GET /auth/microsoft/start`
  - `GET /auth/microsoft/callback`
- Why: these requests originate from magic links and external provider redirects, so they should match the existing CSRF-exempt OAuth flow pattern.

2. **Settings UI connect triggers**
- Location: existing authenticated LiveView (`SettingsLive`) in current `live_session :require_authenticated_settings_user`.
- Why: connect/disconnect actions are account-level settings and must require authenticated `current_scope.settings_user`.

3. **No new `live_session` blocks**
- Keep all new settings behaviors inside the existing `:require_authenticated_settings_user` session.
- Why: AGENTS/auth guidelines require reusing existing generated sessions and avoiding duplicated session names.

## Data Model and Config Plan

### 1) Extend `oauth_tokens` providers

Current providers: `google`, `slack`  
Add:
- `dropbox`
- `microsoft`

Migration work:
- Update DB `valid_provider` CHECK constraint.
- Update schema validation in `Assistant.Schemas.OAuthToken`.

### 2) Extend `auth_tokens` purpose model

Current purposes: `oauth_google`, `telegram_connect`  
Add:
- `oauth_dropbox`
- `oauth_microsoft`

Reason: preserve current purpose-based auditability and avoid overloading existing Google-specific purpose semantics.

### 3) Integration settings keys

Add to `Assistant.IntegrationSettings.Registry`:

#### Dropbox group
- `:dropbox_oauth_client_id`
- `:dropbox_oauth_client_secret`
- `:dropbox_enabled`

#### Microsoft group
- `:microsoft_oauth_client_id`
- `:microsoft_oauth_client_secret`
- `:microsoft_oauth_tenant` (default `common` unless enterprise-specific tenant required)
- `:microsoft_enabled`

### 4) App catalog additions

Add `dropbox` and `microsoft` entries in `AssistantWeb.SettingsLive.Data.app_catalog/0` with:
- setup instructions
- portal/docs links
- `connect_type: :oauth`
- ecosystem scope summary

## OAuth Flow Spec by Provider

### Dropbox OAuth (Authorization Code + PKCE + offline refresh)

1. Settings user clicks Connect Dropbox.
2. `SettingsLive.Events` creates provider-specific magic link token (`oauth_dropbox`).
3. Popup opens `/auth/dropbox/start?token=...`.
4. Start endpoint validates/consumes magic link, redirects to Dropbox authorize URL with:
   - `response_type=code`
   - `client_id`
   - `redirect_uri`
   - `state` (HMAC-signed, provider-aware)
   - `code_challenge`, `code_challenge_method=S256`
   - `token_access_type=offline`
   - `scope` set
5. Callback exchanges code for tokens at Dropbox token endpoint.
6. Store encrypted `access_token` + `refresh_token` in `oauth_tokens` (`provider="dropbox"`).
7. Fetch account identity (`users/get_current_account`) and persist `provider_uid` + `provider_email`.
8. Reuse pending intent replay flow.

### Microsoft OAuth (Authorization Code + PKCE + offline refresh)

1. Settings user clicks Connect Microsoft.
2. `SettingsLive.Events` creates provider-specific magic link token (`oauth_microsoft`).
3. Popup opens `/auth/microsoft/start?token=...`.
4. Start endpoint redirects to Entra authorize URL with:
   - `client_id`
   - `response_type=code`
   - `redirect_uri`
   - `scope` including `openid profile email offline_access` and Graph scopes
   - `state`
   - `code_challenge`, `code_challenge_method=S256`
5. Callback exchanges code at Entra v2 token endpoint using PKCE (+ client secret for confidential web app).
6. Store encrypted tokens in `oauth_tokens` (`provider="microsoft"`).
7. Derive identity from ID token claims and/or Graph `/me`.
8. Reuse pending intent replay flow.

### Disconnect semantics

- Dropbox: call token revoke endpoint, then delete local token row.
- Microsoft: delete local token row; optional remote revoke remains phase-2+ (revocation semantics differ from Google/Dropbox).

## Scope Matrix

### Dropbox (recommended)

| Capability | Scope(s) |
|---|---|
| Account identity display | `account_info.read` (+ optional `openid email profile`) |
| File metadata/search | `files.metadata.read` |
| File read/download | `files.content.read` |
| File write/update/move | `files.content.write` |
| Shared links (optional) | `sharing.read` |

### Microsoft Graph (recommended core)

| Capability | Delegated scope(s) |
|---|---|
| OIDC + refresh tokens | `openid profile email offline_access` |
| OneDrive file read/write | `Files.Read`, `Files.ReadWrite` |
| SharePoint drive discovery/read (if needed) | `Sites.Read.All` (phase-gated) |
| Mail list/read | `Mail.Read` |
| Mail send | `Mail.Send` |
| Calendar list/read | `Calendars.Read` |
| Calendar create/update | `Calendars.ReadWrite` |
| Teams messaging (optional) | `ChatMessage.Send`, `ChannelMessage.Send` |

## Module-Level Plan

### New modules

| File | Purpose |
|---|---|
| `lib/assistant/auth/oauth/dropbox.ex` | Dropbox authorize URL, code exchange, refresh, revoke |
| `lib/assistant/auth/oauth/microsoft.ex` | Microsoft authorize URL, code exchange, refresh |
| `lib/assistant_web/controllers/dropbox_oauth_controller.ex` | `/auth/dropbox/start`, `/auth/dropbox/callback` |
| `lib/assistant_web/controllers/microsoft_oauth_controller.ex` | `/auth/microsoft/start`, `/auth/microsoft/callback` |
| `lib/assistant/integrations/dropbox/files.ex` | Dropbox file APIs mapped to existing files skill semantics |
| `lib/assistant/integrations/microsoft/files.ex` | Graph OneDrive/SharePoint file APIs |
| `lib/assistant/integrations/microsoft/mail.ex` | Graph mail APIs |
| `lib/assistant/integrations/microsoft/calendar.ex` | Graph calendar APIs |
| `lib/assistant_web/components/dropbox_connect_status.ex` | Settings connection widget |
| `lib/assistant_web/components/microsoft_connect_status.ex` | Settings connection widget |

### Existing modules to modify

| File | Change |
|---|---|
| `lib/assistant/auth/magic_link.ex` | Provider-aware purpose/URL generation |
| `lib/assistant/auth/token_store.ex` | Add provider-generic get/upsert/delete helpers + provider-specific wrappers |
| `lib/assistant/schemas/oauth_token.ex` | Add providers: dropbox, microsoft |
| `lib/assistant/schemas/auth_token.ex` | Add purposes: oauth_dropbox, oauth_microsoft |
| `lib/assistant_web/router.ex` | Add Dropbox/Microsoft OAuth routes in `:oauth_browser` scope |
| `lib/assistant_web/live/settings_live/events.ex` | Connect/disconnect handlers for Dropbox/Microsoft |
| `lib/assistant_web/live/settings_live/loaders.ex` | Load connection status and account email for new providers |
| `lib/assistant_web/live/settings_live/state.ex` | Add assigns for new provider connection state |
| `lib/assistant_web/live/settings_live/data.ex` | Add app catalog entries |
| `lib/assistant/integration_settings/registry.ex` | Add integration keys/groups |
| `lib/assistant/integration_settings/connection_validator.ex` | Add real handshake validators |
| `lib/assistant/integrations/registry.ex` | Register Dropbox/Microsoft integration modules |
| `lib/assistant/skills/context.ex` | Add provider token metadata contract |
| `lib/assistant/orchestrator/sub_agent.ex` | Provider-aware lazy auth checks and skill provider routing |
| `lib/assistant/orchestrator/loop_runner.ex` | Build provider token metadata for skill context |

## Skill and Orchestrator Plan

### Skill surface strategy

Keep current domain names:
- `files.*`
- `email.*`
- `calendar.*`

Add optional `provider` flag (`google|dropbox|microsoft`) where relevant:
- `files.search/read/write/update/archive`: all 3 providers
- `email.*`: `google|microsoft`
- `calendar.*`: `google|microsoft`

Default provider resolution:
1. explicit `--provider` if given
2. per-domain user default (new setting, optional)
3. if exactly one provider connected for that domain, use it
4. otherwise return disambiguation error asking user/provider selection

### Lazy auth generalization

Current lazy auth only handles Google skill domains.  
Generalize to:
- detect provider requirements by skill + selected provider
- issue provider-specific magic link
- preserve replay semantics via existing `PendingIntentWorker`

### Integration API shape alignment

To minimize skill churn, keep provider modules with function names compatible with existing handlers:
- Files: `list_files`, `get_file`, `read_file`, `create_file`, `update_file_content`, `move_file`
- Mail: `list_messages`, `get_message`, `search_messages`, `send_message`
- Calendar: `list_events`, `create_event`, `update_event`

## UI / UX Plan

### Apps & Connections

Add two app cards:
- Dropbox
- Microsoft

Each app detail page includes:
- setup instructions (admin)
- OAuth connect/disconnect controls
- connected account badge (email/account label)
- status from `ConnectionValidator`

### Drive-like scoping parity

For files integrations, replicate drive-scoping patterns in phases:
- Phase 1: core CRUD/search parity without complex root-scoping UI
- Phase 2: add connected roots (Dropbox folders, OneDrive/SharePoint drives/sites)
- Phase 3: sync-target browser parity where needed

## Webhooks and Sync Plan (Phase-Gated)

### Dropbox
- Add optional webhook endpoint and signature verification.
- Use webhook as change trigger, then reconcile with `files/list_folder` + cursor continuation.
- Keep polling fallback if webhook delivery is unavailable.

### Microsoft
- Add Graph subscriptions for selected resources.
- Implement webhook validation handshake (`validationToken`) and lifecycle notifications.
- Use delta queries as source of truth after each notification/poll cycle.

## Security and Compliance Requirements

1. Scope minimization
- Start with least-privileged delegated scopes required for current skill set.
- Gate Teams scopes behind explicit feature flag/phase.

2. Token handling
- Continue encrypted token storage via Cloak.
- Never log raw access/refresh tokens.
- Keep refresh token rotation logic provider-aware.

3. OAuth safety
- PKCE required for both new providers.
- HMAC-signed state required for all callbacks.
- 10-minute auth token TTL and single-use consumption preserved.

4. Webhook verification
- Dropbox: verify `X-Dropbox-Signature`.
- Microsoft: validate subscription handshakes and endpoint ownership flow.

5. Req-only HTTP
- Do not introduce Tesla/HTTPoison/httpc for new integrations.

## Testing Plan

### Unit tests (P0)
- Provider OAuth URL generation (state, PKCE, scopes)
- Code exchange success/failure mapping
- Refresh flow and access token cache update
- Token store provider-specific and provider-generic helpers
- Scope resolver / provider selection logic

### Integration tests (P0/P1)
- OAuth start/callback happy paths for Dropbox and Microsoft
- Invalid/expired/used magic-link tokens
- Invalid OAuth state handling
- Connect/disconnect settings UX events
- Connection validator real-handshake stubs
- Skill execution with each provider path

### Regression tests (P0)
- Existing Google OAuth and skills behavior unchanged
- Existing OpenAI/OpenRouter OAuth flows unchanged
- Existing router `live_session` and authenticated settings routes unchanged

## Rollout Plan

### Phase 0: Schema + Config Foundations
1. Expand provider/purpose constraints.
2. Add integration keys and app catalog entries.
3. Add connection state assigns and UI placeholders.

### Phase 1: Dropbox OAuth + Files
1. Implement Dropbox OAuth modules/controllers.
2. Implement Dropbox files client.
3. Wire files skill provider routing.
4. Release behind feature flag.

### Phase 2: Microsoft OAuth + OneDrive/Mail/Calendar
1. Implement Microsoft OAuth modules/controllers.
2. Implement Graph files/mail/calendar clients.
3. Wire files/email/calendar provider routing.
4. Release behind feature flag.

### Phase 3: Ecosystem Enhancements
1. SharePoint site/drive discovery UX.
2. Optional Teams messaging support.
3. Optional webhook + delta based sync enhancements.

### Phase 4: Hardening
1. Full precommit/test pass.
2. Security review of scopes/logging/token lifecycle.
3. Staged rollout and observability checkpoints.

## API Documentation Pack (Official Sources)

### Dropbox
- OAuth Guide: https://developers.dropbox.com/oauth-guide
- Dropbox API reference: https://www.dropbox.com/developers/documentation/http/documentation
- OAuth offline access + refresh tokens: https://dropbox.tech/developers/using-oauth-2-0-with-offline-access
- OIDC guide: https://developers.dropbox.com/oidc-guide
- Webhooks: https://www.dropbox.com/developers/reference/webhooks
- API spec (scopes/routes):
  - https://raw.githubusercontent.com/dropbox/dropbox-api-spec/main/auth.stone
  - https://raw.githubusercontent.com/dropbox/dropbox-api-spec/main/files.stone

### Microsoft (Entra + Graph)
- OAuth auth code flow (v2): https://learn.microsoft.com/en-us/entra/identity-platform/v2-oauth2-auth-code-flow
- App registration: https://learn.microsoft.com/en-us/entra/identity-platform/quickstart-register-app
- Graph permissions reference: https://learn.microsoft.com/en-us/graph/permissions-reference
- Files / OneDrive / SharePoint:
  - https://learn.microsoft.com/en-us/graph/api/driveitem-list-children?view=graph-rest-1.0
  - https://learn.microsoft.com/en-us/graph/api/driveitem-get-content?view=graph-rest-1.0
  - https://learn.microsoft.com/en-us/graph/api/driveitem-put-content?view=graph-rest-1.0
  - https://learn.microsoft.com/en-us/graph/api/driveitem-createuploadsession?view=graph-rest-1.0
  - https://learn.microsoft.com/en-us/graph/api/driveitem-delta?view=graph-rest-1.0
  - https://learn.microsoft.com/en-us/graph/api/drive-list?view=graph-rest-1.0
- Mail:
  - https://learn.microsoft.com/en-us/graph/api/user-list-messages?view=graph-rest-1.0
  - https://learn.microsoft.com/en-us/graph/api/user-sendmail?view=graph-rest-1.0
- Calendar:
  - https://learn.microsoft.com/en-us/graph/api/user-list-events?view=graph-rest-1.0
  - https://learn.microsoft.com/en-us/graph/api/user-post-events?view=graph-rest-1.0
  - https://learn.microsoft.com/en-us/graph/api/event-update?view=graph-rest-1.0
- Notifications + delta:
  - https://learn.microsoft.com/en-us/graph/change-notifications-delivery-webhooks
  - https://learn.microsoft.com/en-us/graph/api/subscription-post-subscriptions?view=graph-rest-1.0
  - https://learn.microsoft.com/en-us/graph/delta-query-overview
- Teams (optional ecosystem extension):
  - https://learn.microsoft.com/en-us/graph/api/chat-post-messages?view=graph-rest-1.0
  - https://learn.microsoft.com/en-us/graph/api/channel-post-messages?view=graph-rest-1.0

## Open Questions to Resolve Before Build Start

1. Provider defaults: should each user define a default provider per domain (`files`, `email`, `calendar`)?
2. Microsoft tenant policy: `common` vs tenant-specific by default for your target customers.
3. Teams phase timing: include in initial Microsoft launch or gate to phase 3.
4. Sync parity timing: ship CRUD/search first or include webhook/delta sync in initial release.

