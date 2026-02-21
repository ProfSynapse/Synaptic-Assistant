# OpenRouter OAuth Implementation Review

**Reviewer**: Backend Coder (Implementation Quality)
**PR**: #19 — OpenRouter PKCE OAuth connect button
**Date**: 2026-02-21

---

## Summary

The implementation is solid overall. The controller follows established patterns from
`SettingsUserOAuthController`, the Accounts context additions are clean and minimal,
and the migration matches existing Cloak encrypted column conventions. I found one
blocking issue (dead controller action) and several minor observations.

---

## Findings

### 1. `disconnect/2` Controller Action Is Dead Code — **Minor**

**File**: `lib/assistant_web/controllers/openrouter_oauth_controller.ex:123-147`
**Router**: `lib/assistant_web/router.ex:100` — `delete "/settings_users/auth/openrouter", OpenRouterOAuthController, :disconnect`

The `disconnect/2` action in the controller is never called by the UI. The
`openrouter_connect_status` component uses `phx-click="disconnect_openrouter"` (line 23
of `openrouter_connect_status.ex`), which routes to the LiveView event handler at
`settings_live.ex:297-309`. The controller action and its DELETE route are dead code.

**Impact**: Not a bug — the disconnect functionality works via LiveView. But the dead
controller action and route add confusion about which path is actually exercised.

**Recommendation**: Remove the `disconnect/2` action from the controller and the
`delete` route from `router.ex`. If a non-LiveView disconnect path is needed in the
future, it can be added then.

---

### 2. Error Handling in `exchange_code_for_key/1` — **Minor (Acceptable)**

**File**: `lib/assistant_web/controllers/openrouter_oauth_controller.ex:181-197`

The function handles three cases:
1. `{:ok, %Req.Response{status: 200, body: %{"key" => key}}}` — success, key is a string
2. `{:ok, %Req.Response{status: status, body: body}}` — any other HTTP response
3. `{:error, reason}` — transport-level failure (DNS, timeout, etc.)

This covers all shapes Req can return. The `json:` option in `Req.post/2` causes Req to
auto-encode the request body as JSON and set `Content-Type: application/json`. Req also
auto-decodes JSON responses when the response Content-Type is `application/json`.

**Potential edge case**: If OpenRouter returns a non-JSON response (e.g., HTML error page
from a reverse proxy), Req won't decode it and `body` will be a raw binary string. The
catch-all clause at line 190-191 handles this correctly — it wraps the status and body
into an error tuple regardless of body type. No issue here.

**One subtlety**: The pattern `%{"key" => key} when is_binary(key)` at line 187 correctly
rejects cases where the `"key"` field is `nil` or a non-string value. Good defensive
pattern.

---

### 3. Session Cleanup (`@pkce_verifier_session_key`) — **Minor (Acceptable)**

**File**: `lib/assistant_web/controllers/openrouter_oauth_controller.ex:76-118`

Session cleanup analysis for the `callback/2` function:

| Path | Verifier Deleted? | Correct? |
|------|-------------------|----------|
| Success (line 86) | Yes | Yes |
| `:not_authenticated` (line 92) | Yes | Yes |
| `:missing_pkce_verifier` (line 97-101) | No | Correct — it's already absent |
| Catch-all `{:error, reason}` (line 107) | Yes | Yes |
| No-code callback (line 113-118) | Yes | Yes |

All paths that could have a verifier in session properly delete it. The
`:missing_pkce_verifier` path correctly does NOT attempt deletion (since
`get_session` already returned nil/empty). No leak.

---

### 4. `fetch_settings_user/1` Pattern — **Minor (Acceptable)**

**File**: `lib/assistant_web/controllers/openrouter_oauth_controller.ex:151-159`

Uses `conn.assigns[:current_scope].settings_user` — this matches the exact pattern in
`settings_live.ex:969-974` (`current_settings_user/1`) which accesses
`socket.assigns[:current_scope]`. The controller uses `conn.assigns` vs the LiveView's
`socket.assigns` but both follow the same `current_scope` -> `settings_user` extraction.

The Google OAuth controller (`settings_user_oauth_controller.ex`) does NOT use this
pattern because it is the login controller itself — users are not yet authenticated. The
OpenRouter controller requires prior authentication, so `fetch_settings_user/1` is the
correct approach.

---

### 5. Accounts Context Functions — **Minor (Clean)**

**File**: `lib/assistant/accounts.ex:408-432`

Three new functions:
- `save_openrouter_api_key/2` (line 413-417)
- `delete_openrouter_api_key/1` (line 422-426)
- `openrouter_connected?/1` (line 431-432)

These follow existing patterns well:
- Use struct guards (`%SettingsUser{} = settings_user`)
- Use `is_binary(api_key)` guard on the save function
- Delegate to a dedicated changeset (`openrouter_api_key_changeset`)
- Return standard `{:ok, struct} | {:error, changeset}` from Repo.update

The `openrouter_connected?/1` function at line 431-432 checks
`openrouter_api_key: key` `when is_binary(key)`. This works correctly with Cloak:
after decryption, a stored key will be a binary string. A `nil` value (no key stored)
matches the second clause.

---

### 6. `load_openrouter_status/1` Encrypted Field Comparison — **Minor**

**File**: `lib/assistant_web/live/settings_live.ex:708-718`

```elixir
%{openrouter_api_key: key} when not is_nil(key) and key != "" ->
  assign(socket, :openrouter_connected, true)
```

The `key != ""` check is defensive but may not be strictly necessary. Cloak-encrypted
fields round-trip through AES-GCM — an empty string `""` encrypted and decrypted would
return `""`. The question is whether `openrouter_api_key_changeset` would ever store an
empty string. Looking at the changeset:

```elixir
def openrouter_api_key_changeset(settings_user, api_key) do
  settings_user |> change(%{openrouter_api_key: api_key})
end
```

It does NOT validate non-empty. If `save_openrouter_api_key/2` were called with `""`,
it would store an encrypted empty string. The `is_binary(api_key)` guard on
`save_openrouter_api_key` would pass `""` through. However, the only caller is the
OAuth controller which only stores keys returned by OpenRouter's API (which will be
non-empty API keys).

**Verdict**: The `key != ""` check is a reasonable safety net. Not a bug, but the
changeset could optionally validate `api_key != ""` for defense-in-depth. Low priority.

---

### 7. Migration Column Type — **No Issue**

**File**: `priv/repo/migrations/20260221170000_add_openrouter_to_settings_users.exs:16`

Uses `:binary` for the `openrouter_api_key` column. This matches the established
pattern for all Cloak-encrypted fields in this codebase:
- `oauth_tokens.refresh_token` → `:binary` (migration 20260219100000)
- `oauth_tokens.access_token` → `:binary` (migration 20260219100000)
- `auth_tokens.code_verifier` → `:binary` (migration 20260220150000)
- `notification_channels.config` → `:binary` (core tables migration)

All use `Assistant.Encrypted.Binary` in the schema and `:binary` in the migration.
Correct.

---

### 8. `Req.post/2` with `json:` Option — **No Issue**

**File**: `lib/assistant_web/controllers/openrouter_oauth_controller.ex:183-186`

```elixir
Req.post(@openrouter_keys_url,
  json: %{"code" => code},
  headers: [{"authorization", "Bearer #{app_key}"}]
)
```

The `json:` option in Req:
- Encodes the map as JSON for the request body
- Sets `Content-Type: application/json` automatically
- Auto-decodes JSON responses (when response Content-Type is JSON)

This matches how OpenRouter's API expects the request. The explicit `headers:` list
for Authorization is also correct — Req merges these with its auto-set headers.

Compare with the Google OAuth controller (`settings_user_oauth_controller.ex:120`) which
uses `form:` instead of `json:` because Google's token endpoint expects
`application/x-www-form-urlencoded`. The choice of `json:` vs `form:` is correct for
each provider.

---

### 9. LiveView Disconnect Handler Error Handling — **Minor**

**File**: `lib/assistant_web/live/settings_live.ex:297-309`

```elixir
def handle_event("disconnect_openrouter", _params, socket) do
  case current_settings_user(socket) do
    nil ->
      {:noreply, put_flash(socket, :error, "You must be logged in.")}

    settings_user ->
      Accounts.delete_openrouter_api_key(settings_user)

      {:noreply,
       socket
       |> assign(:openrouter_connected, false)
       |> put_flash(:info, "OpenRouter disconnected.")}
  end
end
```

The return value of `Accounts.delete_openrouter_api_key(settings_user)` is ignored.
Compare with `disconnect_google` (line 265-294) which does not check the return of
`TokenStore.delete_google_token/1` either. And compare with the controller's
`disconnect/2` (the dead code at line 123-147) which DOES check the return value.

Since the LiveView is the actual code path used, the ignored return value means a
database error during key deletion would show a success flash. However, `Repo.update`
with a simple `change(%{openrouter_api_key: nil})` is extremely unlikely to fail (no
validations, no constraints). The risk is negligible and consistent with the Google
disconnect pattern.

---

## Verdict

| # | Finding | Severity | Action Needed |
|---|---------|----------|---------------|
| 1 | Dead `disconnect/2` controller action + DELETE route | Minor | Remove dead code |
| 2 | Error handling in `exchange_code_for_key/1` | Acceptable | None |
| 3 | Session cleanup completeness | Acceptable | None |
| 4 | `fetch_settings_user/1` pattern | Acceptable | None |
| 5 | Accounts context functions | Clean | None |
| 6 | Encrypted field `!= ""` check | Minor | Optional: add changeset validation |
| 7 | Migration column type | No Issue | None |
| 8 | `Req.post/2` with `json:` | No Issue | None |
| 9 | LiveView disconnect ignores return | Minor | Consistent with existing patterns |

**Overall**: The implementation is clean and follows established codebase patterns well.
The one actionable item is removing the dead `disconnect/2` controller action and its
DELETE route. All other findings are acceptable or informational.
