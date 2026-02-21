# Security Review: OpenRouter PKCE OAuth Connect Button (PR #19)

**Reviewer**: pact-security-engineer
**Date**: 2026-02-21
**Scope**: OpenRouter OAuth PKCE flow, encrypted key storage, route security

---

## Attack Surface Map

**Entry points reviewed:**
- `GET /settings_users/auth/openrouter` (initiate OAuth)
- `GET /settings_users/auth/openrouter/callback?code=...` (callback)
- `DELETE /settings_users/auth/openrouter` (disconnect)
- `handle_event("disconnect_openrouter", ...)` (LiveView disconnect)

**Trust boundaries crossed:**
- Browser session -> Phoenix controller (session-based auth)
- Phoenix controller -> OpenRouter API (app API key in Authorization header)
- OpenRouter API -> Phoenix controller (authorization code, permanent API key)
- Controller -> Ecto/DB (encrypted field storage via Cloak AES-GCM)

---

## Findings

### FINDING: MEDIUM -- PKCE code_verifier fetched but not sent during token exchange

**Location**: `lib/assistant_web/controllers/openrouter_oauth_controller.ex:78-79`
**Issue**: In `callback/2`, the code_verifier is fetched from the session (`fetch_pkce_verifier(conn)`) and bound as `{:ok, _code_verifier}` (underscore-prefixed, unused). The `exchange_code_for_key/1` function at line 181 never receives or sends the code_verifier to OpenRouter's token endpoint.

**Attack vector**: If OpenRouter does not verify the PKCE challenge server-side (which the code comments at line 7-10 suggest -- "non-standard OAuth flow"), then the entire PKCE flow is security theater. An attacker who intercepts the authorization code (e.g., via referrer leakage, browser history, or open redirect on the callback URL) could replay it without the verifier.

However: the code at line 184 shows the token exchange uses `%{"code" => code}` only, authenticated with the app API key via Bearer token. This means code replay requires both:
1. The intercepted authorization code
2. The app API key (server-side only)

This significantly limits the attack surface. The PKCE is "best effort" given OpenRouter's API constraints.

**Severity assessment**: MEDIUM -- The code_verifier is correctly generated and stored but never transmitted. If OpenRouter adds server-side PKCE verification in the future, this would silently break. The current risk is limited because the token exchange requires the app API key (which only the server has).

**Remediation**:
1. Add a code comment explicitly documenting that OpenRouter's `/api/v1/auth/keys` endpoint does not accept a `code_verifier` parameter
2. Consider sending the code_verifier anyway (if OpenRouter ignores unknown fields) for forward-compatibility
3. If OpenRouter adds PKCE verification support in the future, the exchange call must be updated

---

### FINDING: MEDIUM -- No CSRF state parameter in OAuth flow

**Location**: `lib/assistant_web/controllers/openrouter_oauth_controller.ex:41-47` (request), lines 76-111 (callback)
**Issue**: The OAuth initiation does not include a `state` parameter. The Google OAuth controller (`settings_user_oauth_controller.ex:17-18, 42, 97-107`) uses a cryptographic state token stored in the session and verified on callback with `Plug.Crypto.secure_compare`. The OpenRouter flow has no equivalent.

**Attack vector**: Classic OAuth CSRF -- An attacker could:
1. Initiate their own OpenRouter OAuth flow
2. Get an authorization code for *their* OpenRouter account
3. Craft a URL: `/settings_users/auth/openrouter/callback?code=ATTACKER_CODE`
4. Trick a logged-in victim into visiting that URL
5. The victim's account would be connected to the attacker's OpenRouter API key

This would allow the attacker to:
- Monitor the victim's API usage (if OpenRouter provides usage dashboards per key)
- Potentially revoke the key later, causing service disruption
- Consume the victim's application requests through the attacker's billing

**Mitigating factors**:
- The routes are in the `:browser` pipeline which includes `:protect_from_forgery` (CSRF plug). However, the callback is a GET request from OpenRouter's redirect, so CSRF tokens don't apply to it. The CSRF plug protects the DELETE disconnect action.
- The session must already exist (user must be logged in) for the callback to succeed.
- The PKCE verifier in the session acts as a *partial* CSRF mitigation: the attacker would need the victim's session to already contain a PKCE verifier from a `request` action. If the victim hasn't initiated the flow themselves, `fetch_pkce_verifier/1` will return `{:error, :missing_pkce_verifier}` and reject the callback.

**Severity assessment**: MEDIUM -- The PKCE verifier check provides meaningful (but not purpose-built) CSRF protection. An attacker cannot forge a callback unless the victim has also independently initiated an OpenRouter OAuth flow (creating a race condition). This is a defense-in-depth gap, not an immediately exploitable vulnerability.

**Remediation**: Add an explicit `state` parameter following the pattern in `SettingsUserOAuthController`:
1. Generate a random state in `request/2`, store in session
2. Include `state` in the redirect URL (if OpenRouter passes it back) or in the callback URL as a path/query parameter
3. Verify state in `callback/2` with `Plug.Crypto.secure_compare`
4. If OpenRouter does not support `state` passthrough, document this limitation

---

### FINDING: LOW -- Potential API key exposure in error logs

**Location**: `lib/assistant_web/controllers/openrouter_oauth_controller.ex:104`
**Issue**: The catch-all error branch logs `inspect(reason)`. When the error is `{:openrouter_key_exchange_failed, status, body}` (line 191), the `body` from OpenRouter's response could theoretically contain sensitive information. More critically, if Req includes request details in error structs (e.g., `Req.TransportError`), the `Authorization: Bearer #{app_key}` header from line 185 could be included in the logged `reason`.

**Attack vector**: An attacker with access to application logs could extract the `OPENROUTER_APP_API_KEY`. This is a defense-in-depth concern, not a direct exploit.

**Severity assessment**: LOW -- Req's `TransportError` struct typically contains connection-level errors (DNS, TLS, timeout), not request headers. The more likely log exposure is the OpenRouter response body, which may contain error details but not the app key. However, the principle of minimal logging applies.

**Remediation**:
1. Log a sanitized version of the error: `reason: inspect(reason, limit: 200)` or extract only the relevant error type
2. Ensure Req is not configured to log request headers at debug level in production

---

### FINDING: LOW -- No validation on received API key format

**Location**: `lib/assistant_web/controllers/openrouter_oauth_controller.ex:187`
**Issue**: The key received from OpenRouter is checked only for being a binary (`when is_binary(key)`). There is no validation of the key format, length, or prefix (OpenRouter keys typically start with `sk-or-`).

**Attack vector**: If OpenRouter's response is compromised (MITM, DNS poisoning), an attacker could inject an arbitrary string as the "key" which would be stored encrypted in the database. On its own this is low-impact (the bad key would simply fail on use), but it represents a missed input validation opportunity.

**Severity assessment**: LOW -- The key is stored encrypted and only used server-side. A bad key would cause API failures, not a security breach. The HTTPS connection to OpenRouter provides transport-level protection.

**Remediation**: Add basic format validation (e.g., `String.starts_with?(key, "sk-or-")` and `String.length(key) > 10`).

---

### FINDING: INFO -- Session fixation considerations

**Location**: `lib/assistant_web/controllers/openrouter_oauth_controller.ex:53`
**Issue**: The PKCE verifier is stored in the session via `put_session/3`. If an attacker could fixate a victim's session (pre-plant session data), they could plant a known `code_verifier`.

**Assessment**: NOT EXPLOITABLE. Phoenix sessions are signed and encrypted by default (`secret_key_base` + cookie signing). The `:browser` pipeline's `fetch_session` plug handles this. Session fixation would require the attacker to know the `secret_key_base`, which would represent a complete compromise. Additionally, even with a known verifier, the attacker would still need the authorization code AND the app API key to complete the exchange.

---

## Area-by-Area Assessment

### Auth & access control
- `fetch_settings_user/1` (line 151-158): Correctly checks `conn.assigns[:current_scope]` for a `SettingsUser` struct. Returns `{:error, :not_authenticated}` when absent. This is consistent with the existing pattern.
- The OpenRouter routes are in the `:browser` pipeline (router.ex:92-101) which runs `fetch_current_scope_for_settings_user`. This means the scope is populated.
- The routes are NOT behind `require_authenticated_settings_user` (lines 72-90 use that plug, but lines 92-112 do not). This means unauthenticated users can reach the controller -- which is handled correctly by `fetch_settings_user/1` returning `:not_authenticated` and redirecting to login.
- **No issues found** -- authentication checks are correct and consistent.

### Input handling
- The `code` parameter from the callback (line 76) is passed directly to `exchange_code_for_key/1` and then into `Req.post` as a JSON body value. Since it's sent as structured JSON (not interpolated into a URL or query), there is no injection risk.
- No SQL injection risk -- all database operations go through Ecto changesets.
- **No issues found.**

### Data exposure
- The `openrouter_api_key` field is typed as `Assistant.Encrypted.Binary` (settings_user.ex:15), matching the pattern used for Google OAuth tokens (oauth_token.ex:21-22). This ensures encryption at rest via Cloak AES-GCM.
- The migration (line 16) uses `:binary` column type, which is correct for encrypted data.
- Logger calls log only `settings_user_id`, not the API key itself. The catch-all at line 104 logs `inspect(reason)` which could include response bodies but not the user's API key.
- The `load_openrouter_status/1` function (settings_live.ex:708-718) checks for key presence but never sends the key value to the client -- only a boolean `openrouter_connected`.
- **No issues found** -- encrypted storage is correctly applied.

### Dependency risk
- No new dependencies introduced.
- **No issues found.**

### Cryptographic misuse
- PKCE code_verifier generation (line 201-203): Uses `:crypto.strong_rand_bytes(32)` with Base64url encoding. This is correct -- 32 bytes provides 256 bits of entropy.
- PKCE code_challenge (line 206-208): Uses `:crypto.hash(:sha256, verifier)` with Base64url encoding. This follows the S256 PKCE spec (RFC 7636).
- **No issues found** -- cryptographic operations are correct.

### Configuration
- `OPENROUTER_APP_API_KEY` (runtime.exs:62-64): Loaded from environment variable, stored in application config. Never compiled into the release. Not logged.
- The app key is distinct from `OPENROUTER_API_KEY` (runtime.exs:55-57), which is the system-wide key for chat completions. Good separation.
- **No issues found.**

---

## SECURITY REVIEW SUMMARY

| Severity | Count | Details |
|----------|-------|---------|
| Critical | 0 | -- |
| High | 0 | -- |
| Medium | 2 | PKCE verifier unused in exchange; No state param (CSRF) |
| Low | 2 | Error log exposure potential; No key format validation |
| Info | 1 | Session fixation not exploitable |

**Overall assessment: PASS WITH CONCERNS**

The implementation follows sound security practices: encrypted storage, session-based auth checks, strong PRNG for PKCE, and minimal data logging. The two MEDIUM findings represent defense-in-depth gaps rather than immediately exploitable vulnerabilities:

1. **PKCE verifier unused**: Correctly generated but not sent to OpenRouter during token exchange. This appears to be a constraint of OpenRouter's non-standard API (which uses app API key authentication instead of standard PKCE verification). Risk is mitigated by the server-side app key requirement.

2. **No state parameter**: The PKCE verifier in the session provides incidental CSRF protection (callback fails if no verifier in session), but this is not purpose-built CSRF defense. Adding an explicit state parameter would be better but may not be supported by OpenRouter's flow.

Neither finding is blocking for merge. Both should be tracked as follow-up items for hardening.
