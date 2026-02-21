# OpenRouter OAuth — Test Coverage Review

**Reviewer**: pact-test-engineer
**Risk Tier**: HIGH (OAuth flow, credential storage, first-time pattern for OpenRouter)
**Date**: 2026-02-21

---

## 1. Current Coverage Summary

### What Exists

| File | Covers | Notes |
|------|--------|-------|
| `test/assistant/integrations/openrouter_test.exs` | LLM client pure functions (`build_request_body`, `sort_tools`, `cached_content`, `audio_content`, error paths) | Does NOT test the new OAuth controller or Accounts functions |

### What Is Missing

**No controller tests exist for `OpenRouterOAuthController`.**
**No Accounts context tests exist for the 3 new `openrouter_*` functions.**
**No SettingsUser schema test for `openrouter_api_key_changeset/2`.**

---

## 2. Missing Controller Tests

File to create: `test/assistant_web/controllers/openrouter_oauth_controller_test.exs`

Pattern reference: `settings_user_oauth_controller_test.exs` (Google OAuth for settings_users — same route scope, same ConnCase setup).

### 2.1 `request/2` — OAuth Initiation

| Test Name | Severity | Description |
|-----------|----------|-------------|
| `"request/2 redirects to OpenRouter with PKCE params when authenticated and configured"` | **Blocking** | Happy path: logged-in user, app key set. Assert redirect to `openrouter.ai/auth?...`, session contains PKCE verifier, URL has `callback_url`, `code_challenge`, `code_challenge_method=S256`. |
| `"request/2 redirects to login when not authenticated"` | **Blocking** | No session / no `current_scope`. Assert redirect to `/settings_users/log-in`, flash error about login. |
| `"request/2 redirects to settings when OPENROUTER_APP_API_KEY not configured"` | **Blocking** | `Application.delete_env(:assistant, :openrouter_app_api_key)`. Assert redirect to `/settings`, flash error about not configured. |
| `"request/2 generates a valid PKCE S256 challenge"` | **Minor** | Verify `code_challenge` in redirect URL matches `Base.url_encode64(:crypto.hash(:sha256, session_verifier), padding: false)`. |

### 2.2 `callback/2` — Code Exchange

| Test Name | Severity | Description |
|-----------|----------|-------------|
| `"callback/2 exchanges code and stores API key on success"` | **Blocking** | Use Bypass to mock `POST /api/v1/auth/keys` returning `%{"key" => "sk-or-test-key"}`. Assert redirect to `/settings`, flash success, `settings_user.openrouter_api_key` is set (reload from DB), PKCE verifier cleared from session. |
| `"callback/2 redirects to login when not authenticated"` | **Blocking** | No session. Assert redirect to `/settings_users/log-in`. |
| `"callback/2 redirects to settings when PKCE verifier missing from session"` | **Blocking** | Authenticated but no verifier in session. Assert redirect to `/settings`, flash error about "try again". |
| `"callback/2 redirects to settings when code exchange returns non-200"` | **Blocking** | Bypass returns `{status: 401, body: %{"error" => "invalid_code"}}`. Assert redirect to `/settings`, flash error. |
| `"callback/2 redirects to settings when code exchange returns unexpected body"` | **Minor** | Bypass returns `{status: 200, body: %{"something" => "else"}}` (no `"key"` field). Assert redirect to `/settings`, flash error. |
| `"callback/2 redirects to settings when code exchange HTTP request fails"` | **Minor** | Bypass down/unreachable. Assert redirect to `/settings`, flash error. |
| `"callback/2 handles missing code param (cancellation)"` | **Blocking** | `GET /callback` with no `code` param. Assert redirect to `/settings`, flash error about cancelled/failed, verifier cleared. |

### 2.3 `disconnect/2` — API Key Removal

| Test Name | Severity | Description |
|-----------|----------|-------------|
| `"disconnect/2 removes API key and redirects to settings"` | **Blocking** | Pre-set `openrouter_api_key` on settings_user. `DELETE /settings_users/auth/openrouter`. Assert redirect to `/settings`, flash success, `settings_user.openrouter_api_key` is nil (reload from DB). |
| `"disconnect/2 redirects to login when not authenticated"` | **Blocking** | No session. Assert redirect to `/settings_users/log-in`. |
| `"disconnect/2 succeeds even when no API key was stored"` | **Minor** | Call disconnect on a user with no key set. Should still succeed (changeset sets nil → nil). |

---

## 3. Missing Accounts Context Tests

File to update: `test/assistant/accounts_test.exs`

### 3.1 `save_openrouter_api_key/2`

| Test Name | Severity | Description |
|-----------|----------|-------------|
| `"save_openrouter_api_key/2 stores encrypted API key"` | **Blocking** | Create settings_user, call `save_openrouter_api_key(user, "sk-or-test")`. Assert `{:ok, user}`, reload shows `openrouter_api_key == "sk-or-test"`. |
| `"save_openrouter_api_key/2 overwrites existing key"` | **Minor** | Save once, save again with different key. Assert second key is stored. |

### 3.2 `delete_openrouter_api_key/1`

| Test Name | Severity | Description |
|-----------|----------|-------------|
| `"delete_openrouter_api_key/1 removes stored key"` | **Blocking** | Save a key first, then delete. Assert `{:ok, user}` with `openrouter_api_key == nil`. |
| `"delete_openrouter_api_key/1 succeeds when no key stored"` | **Minor** | Call on user with no key. Assert `{:ok, user}`. |

### 3.3 `openrouter_connected?/1`

| Test Name | Severity | Description |
|-----------|----------|-------------|
| `"openrouter_connected?/1 returns true when key exists"` | **Blocking** | `%SettingsUser{openrouter_api_key: "sk-or-test"}` → `true`. |
| `"openrouter_connected?/1 returns false when key is nil"` | **Blocking** | `%SettingsUser{openrouter_api_key: nil}` → `false`. |
| `"openrouter_connected?/1 returns false for non-SettingsUser"` | **Minor** | `openrouter_connected?(nil)` → `false`. |

---

## 4. Mock Strategy for HTTP Calls

### Recommendation: Bypass

The project already has `{:bypass, "~> 2.1", only: :test}` in `mix.exs` and uses Bypass in `oauth_controller_callback_test.exs` for Google token exchange.

For the OpenRouter code exchange (`POST https://openrouter.ai/api/v1/auth/keys`), the controller hardcodes `@openrouter_keys_url`. To use Bypass:

**Option A (Recommended): Module attribute override via Application env**
Add a config-driven URL override:
```elixir
# In the controller:
defp keys_url do
  Application.get_env(:assistant, :openrouter_keys_url, @openrouter_keys_url)
end
```
Then in tests:
```elixir
setup do
  bypass = Bypass.open()
  Application.put_env(:assistant, :openrouter_keys_url, "http://localhost:#{bypass.port}/api/v1/auth/keys")
  on_exit(fn -> Application.delete_env(:assistant, :openrouter_keys_url) end)
  %{bypass: bypass}
end
```

**Option B: Req.Test plug**
Req supports `Req.Test.stub/2` for plugging test handlers, but the controller calls `Req.post` directly without a named Req instance, so this would require refactoring the `exchange_code_for_key/1` function to accept a Req option or use a registered Req name.

**Option C: Mox with behaviour**
Extract an OpenRouter OAuth behaviour and mock it. Heavier refactoring, but cleanest isolation.

**Verdict**: Option A is the smallest change and follows the pattern already used for Google OAuth credentials. It only adds one private helper function and one Application.get_env call.

---

## 5. Edge Cases Not Covered

| Edge Case | Risk | Status |
|-----------|------|--------|
| Missing `OPENROUTER_APP_API_KEY` at request time | Medium | **Not tested** — controller handles it, but no test verifies the flash/redirect |
| Expired authorization code at exchange time | Medium | **Not tested** — would come back as non-200 from OpenRouter API |
| Session verifier mismatch (different session than initiation) | High | **Not tested** — controller checks for verifier presence but verifier is never sent to OpenRouter in exchange; OpenRouter validates the code itself |
| Disconnect when already disconnected | Low | **Not tested** — should succeed (nil → nil) |
| Concurrent connect attempts (race condition) | Low | Unlikely in practice; single-user session flow |
| PKCE verifier stored in session but OpenRouter returns error | Medium | **Not tested** — should clean up session and show error |
| API key encryption at rest | Medium | Covered by Cloak integration, but no test verifies `settings_user.openrouter_api_key` is actually encrypted in DB |

---

## 6. Existing Pattern Reference

### `settings_user_oauth_controller_test.exs` (Google OAuth for settings_users)

- Uses `ConnCase, async: false` (modifies Application env)
- `setup` block saves/restores Application env for client_id/client_secret
- Tests unauthenticated routes (no `register_and_log_in_settings_user` setup)
- Tests redirect target and flash messages
- Tests session state management

### `oauth_controller_callback_test.exs` (Google per-user OAuth)

- Uses Bypass for mocking Google token endpoint
- Tests happy path with full flow: token → redirect → callback → storage
- Tests state validation, denial, missing params
- Uses `async: false`

The new `openrouter_oauth_controller_test.exs` should combine both patterns:
- `ConnCase, async: false` for Application env manipulation
- `register_and_log_in_settings_user` setup for authenticated routes
- Bypass for the code exchange HTTP call
- Test both authenticated and unauthenticated paths

---

## 7. Summary

| Category | Count | Blocking | Minor |
|----------|-------|----------|-------|
| Controller tests (missing) | 12 | 9 | 3 |
| Accounts context tests (missing) | 7 | 5 | 2 |
| **Total missing** | **19** | **14** | **5** |

**Risk Assessment**: HIGH — This is an OAuth flow handling credential storage. The controller has zero test coverage. The 3 new Accounts functions have zero test coverage. The code itself looks well-structured (good error handling, PKCE implementation, session cleanup), but without tests there is no verification of these behaviors.

**Recommendation**: Write controller + Accounts context tests before merge. The controller tests should use Bypass for the HTTP exchange endpoint (requires a small refactoring to make the URL configurable, ~3 lines changed). The Accounts tests are pure DB operations and straightforward.
