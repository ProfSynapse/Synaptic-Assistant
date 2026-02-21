# Architectural Review: OpenRouter PKCE OAuth Connect Button (PR #19)

**Reviewer**: architect-reviewer
**Date**: 2026-02-21
**Scope**: Design coherence, storage decisions, pattern alignment, separation of concerns

---

## Executive Summary

The OpenRouter OAuth implementation is architecturally sound. It correctly identifies that OpenRouter's "PKCE OAuth" flow is fundamentally different from the existing Google OAuth2 flows (which produce refresh-able, expiring tokens). The key architectural decision -- storing a permanent API key on `settings_users` rather than in the `oauth_tokens`/`auth_tokens` tables -- is the right call given the nature of the credential. The controller is well-separated, the Accounts context functions are appropriately scoped, and the component follows existing patterns.

**Overall Rating**: Approve with minor suggestions.

---

## Question 1: Storage Location -- `settings_users` vs `oauth_tokens`

**Rating**: Correct decision. No action needed.

**Analysis**:

The existing token tables serve distinct purposes that don't fit OpenRouter's model:

| Table | Purpose | Lifecycle | Fits OpenRouter? |
|-------|---------|-----------|------------------|
| `oauth_tokens` | Google OAuth2 access + refresh tokens | Expiring, refreshable, revocable | No |
| `auth_tokens` | Single-use magic link tokens for OAuth initiation | Consumed once, short-lived | No |
| `settings_users` | User profile + credentials | Persistent, user-owned | Yes |

OpenRouter's flow produces a **permanent API key** with no expiry, no refresh token, and no revocation endpoint. This is semantically a user credential/preference, not a token lifecycle to manage. Storing it on `settings_users`:

- Avoids polluting the token tables with a fundamentally different credential type
- Eliminates unnecessary complexity (no refresh logic, no expiry checks, no cleanup workers)
- Uses `Assistant.Encrypted.Binary` (Cloak AES-GCM) for encryption at rest -- same pattern as `code_verifier` in `auth_tokens`
- Migration is a clean additive column (`priv/repo/migrations/20260221170000_add_openrouter_to_settings_users.exs:14-17`)

**Future consideration** (not blocking): If more third-party API keys follow this pattern (permanent, non-expiring keys from OAuth-like flows), consider whether a dedicated `connected_services` or `api_credentials` table would be cleaner than adding columns to `settings_users`. For a single integration, the current approach is appropriate and avoids over-engineering.

---

## Question 2: Controller Separation from Accounts Context

**Rating**: Well-separated. No issues.

**Analysis**:

`OpenRouterOAuthController` (`lib/assistant_web/controllers/openrouter_oauth_controller.ex`) has clear boundaries:

- **Controller responsibilities** (correctly placed):
  - PKCE generation (lines 38-39, 201-208)
  - Session management for code_verifier (lines 53, 86, 162-168)
  - HTTP interaction with OpenRouter API (lines 181-196)
  - Flash messages and redirects
  - Authentication guard via `fetch_settings_user/1` (lines 151-158)

- **Accounts context responsibilities** (correctly delegated):
  - `save_openrouter_api_key/2` -- persistence (accounts.ex:413-416)
  - `delete_openrouter_api_key/1` -- removal (accounts.ex:422-425)
  - `openrouter_connected?/1` -- query (accounts.ex:431-432)

The controller does not reach into Repo directly. All data mutations go through the Accounts context. The OpenRouter-specific HTTP exchange logic stays in the controller, which is appropriate since it's web-layer protocol handling, not business logic.

**Observation**: The Accounts context functions (lines 408-432) are grouped under an `## OpenRouter` section comment, keeping them organized alongside the existing Google OAuth functions. This is clean.

---

## Question 3: PKCE Flow Pattern Comparison

**Rating**: Consistent with project patterns. Minor difference justified.

**Comparison with `SettingsUserOAuthController`**:

| Aspect | Google OAuth (`settings_user_oauth_controller.ex`) | OpenRouter OAuth (`openrouter_oauth_controller.ex`) |
|--------|-----------------------------------------------------|------------------------------------------------------|
| Anti-CSRF | Random `state` param + session storage | PKCE `code_verifier` + S256 challenge (no state param) |
| Code exchange | POST to Google token endpoint with client_secret | POST to OpenRouter keys endpoint with Bearer app key |
| Result | access_token + id_token (user identity) | Permanent API key |
| Session cleanup | Deletes state from session on callback | Deletes verifier from session on callback |
| Error handling | `with` chain + pattern-matched error clauses | `with` chain + pattern-matched error clauses |
| Auth check | Not applicable (login flow, no pre-auth needed) | `fetch_settings_user/1` guard (must be logged in) |

**Key structural difference**: The Google OAuth controller is a *login* flow (creates/finds a user, starts a session). The OpenRouter controller is a *connect* flow (user must already be authenticated; adds a credential). This justifies the `fetch_settings_user/1` guard in OpenRouter that doesn't exist in Google OAuth.

**PKCE implementation** (lines 201-208): Uses `:crypto.strong_rand_bytes(32)` with `Base.url_encode64(padding: false)` for the verifier, and `:crypto.hash(:sha256, ...)` for the S256 challenge. This matches the PKCE RFC 7636 specification correctly.

**No `state` parameter**: OpenRouter's auth endpoint uses PKCE S256 as the CSRF-equivalent protection. The verifier is stored server-side in the session and never transmitted (only the hash goes to OpenRouter). This is correct per their documented flow.

---

## Question 4: Accounts Context Function Design

**Rating**: Well-designed. No issues.

**Functions reviewed**:

1. **`save_openrouter_api_key/2`** (accounts.ex:413-416): Clean delegation to changeset. Guard clause `when is_binary(api_key)` prevents nil/non-string values at the context boundary. Returns `{:ok, settings_user}` or `{:error, changeset}`.

2. **`delete_openrouter_api_key/1`** (accounts.ex:422-425): Reuses the same changeset with `nil`, which is a clean approach. The changeset (`openrouter_api_key_changeset/2` at settings_user.ex:149-152) uses `change/2` rather than `cast/2`, which is appropriate for programmatic updates that don't come from user input.

3. **`openrouter_connected?/1`** (accounts.ex:431-432): Pattern-matched function heads. Clean and efficient -- no database query needed since the field is on the struct. The `when is_binary(key)` guard correctly handles the `nil` case without an explicit nil check.

**Observation**: These functions follow the same minimal-surface-area pattern as the existing Accounts functions. They don't over-abstract or add unnecessary intermediate types.

---

## Question 5: Route Placement

**Rating**: Correct pipeline. One observation.

**Current placement** (router.ex:92-101):

```elixir
scope "/", AssistantWeb do
  pipe_through [:browser]

  get "/settings_users/auth/google", SettingsUserOAuthController, :request
  get "/settings_users/auth/google/callback", SettingsUserOAuthController, :callback

  get "/settings_users/auth/openrouter", OpenRouterOAuthController, :request
  get "/settings_users/auth/openrouter/callback", OpenRouterOAuthController, :callback
  delete "/settings_users/auth/openrouter", OpenRouterOAuthController, :disconnect
end
```

**Pipeline analysis**: The `:browser` pipeline (lines 13-21) includes:
- `:fetch_session` -- needed for PKCE verifier storage
- `:protect_from_forgery` -- CSRF protection for the initial `GET /request`
- `:fetch_current_scope_for_settings_user` -- needed for `fetch_settings_user/1`

This is correct. The OpenRouter routes need all three. They do NOT belong in `oauth_browser` (which lacks CSRF and session auth), nor in the `require_authenticated_settings_user` scope (because the callback redirect from OpenRouter won't carry LiveView auth tokens -- the controller handles auth checking internally via `fetch_settings_user/1`).

**Observation (Minor)**: The Google OAuth login routes (`/settings_users/auth/google`) are in the same `:browser` scope. This works because the Google flow is a login action (no pre-auth required), while the OpenRouter flow is a connect action that checks auth internally. Both correctly avoid the `require_authenticated_settings_user` scope. The internal auth check in the OpenRouter controller (via `conn.assigns[:current_scope]`) is the right approach here -- the plug pipeline sets up the assigns, the controller checks them.

---

## Question 6: Component Pattern Comparison

**Rating**: Follows existing pattern. One minor CSS class naming observation.

**Comparison**:

| Aspect | `GoogleConnectStatus` | `OpenRouterConnectStatus` |
|--------|----------------------|--------------------------|
| `@moduledoc` | `false` | `false` |
| Required attrs | `connected` (boolean) | `connected` (boolean) |
| Optional attrs | `email` (string, default nil) | None |
| Disconnect event | `phx-click="disconnect_google"` | `phx-click="disconnect_openrouter"` |
| Connect link | `href="/auth/google/start?from=settings"` | `href="/settings_users/auth/openrouter"` |
| CSS classes | `sa-google-status-*` | `sa-google-status-*` (reused) |

**Pattern alignment**: The component correctly mirrors the Google component's structure. The absence of an `email` attr is appropriate -- OpenRouter doesn't provide user identity information in the key exchange response.

**Observation (Minor/Future)**: Both components reuse CSS class names prefixed with `sa-google-status-*`. This works but is semantically misleading -- the classes aren't Google-specific anymore. A future refactor could rename them to `sa-connect-status-*` or extract a shared component. This is purely cosmetic and not blocking.

---

## Additional Architectural Observations

### A1: Per-User Key Threading (Future/Not Blocking)

The `openrouter.ex` integration module currently uses only the system-level API key (`Application.fetch_env!(:assistant, :openrouter_api_key)` at openrouter.ex:673). There is no code path yet that retrieves the per-user key from `settings_users` and passes it to the OpenRouter API client. This means:

- The OAuth flow stores the key successfully
- The settings UI shows connected/disconnected status correctly
- But chat completions still use the system key for all users

This is likely intentional for this PR (connect button only), with key threading planned for a subsequent PR. If so, this is fine. If not, it should be tracked as a follow-up task.

### A2: No Revocation Endpoint (Acknowledged)

The controller header comment (lines 10) correctly documents that OpenRouter has "No refresh tokens, no expiry, no revocation endpoint." The disconnect flow (lines 123-147) correctly handles this by simply deleting the stored key locally. There's no remote revocation call needed (unlike Google OAuth which POSTs to `https://oauth2.googleapis.com/revoke`). The `data-confirm` dialog on the disconnect button appropriately warns the user.

### A3: App API Key Configuration

The `OPENROUTER_APP_API_KEY` env var (runtime.exs:62-64) is correctly separated from the existing `OPENROUTER_API_KEY` (system-level key for chat completions). The naming is clear and the controller's `fetch_app_api_key/0` (lines 171-178) gracefully handles the unconfigured case by flashing an error and redirecting, rather than crashing.

---

## Summary of Findings

| # | Finding | Severity | Action |
|---|---------|----------|--------|
| 1 | Storage on `settings_users` is correct for permanent API key | N/A (affirmed) | None |
| 2 | Controller well-separated from Accounts context | N/A (affirmed) | None |
| 3 | PKCE flow correctly adapted to OpenRouter's non-standard OAuth | N/A (affirmed) | None |
| 4 | Accounts functions well-designed, minimal surface area | N/A (affirmed) | None |
| 5 | Routes in correct pipeline with proper auth handling | N/A (affirmed) | None |
| 6 | Component follows Google pattern structurally | N/A (affirmed) | None |
| A1 | Per-user key not yet threaded to OpenRouter API client | Future | Track as follow-up if not already planned |
| A2 | No remote revocation needed (correctly documented) | N/A (affirmed) | None |
| A3 | CSS classes use `sa-google-status-*` prefix for non-Google component | Minor/Future | Consider renaming to `sa-connect-status-*` in future refactor |

**Verdict**: Architecturally sound. Approve.
