# Phase 3 Security Review

**Reviewer**: pact-security-engineer
**Date**: 2026-02-18
**Scope**: Google Chat webhook + JWT auth, Drive integration, file skills, notifications

---

## FINDING: CRITICAL -- GoogleChatAuth plug is defined but never applied

**Location**: `lib/assistant_web/router.ex:21-26`
**Issue**: The `GoogleChatAuth` plug (`AssistantWeb.Plugs.GoogleChatAuth`) is fully implemented in `lib/assistant_web/plugs/google_chat_auth.ex` but is **never referenced** in the router or controller. The `/webhooks/google-chat` route passes through only the `:api` pipeline (line 22), which does nothing more than `plug :accepts, ["json"]`. There is no pipeline or inline plug that invokes `GoogleChatAuth`.

The controller comments (lines 4, 20, 46 of `google_chat_controller.ex`) claim the plug has "already verified the JWT by this point," but this is false -- no JWT verification occurs on any request to this endpoint.

**Attack vector**: Any unauthenticated attacker who knows the webhook URL can POST arbitrary JSON to `/webhooks/google-chat`. Because the controller normalizes the raw params and spawns async orchestrator processing (including LLM calls), an attacker can:
1. Trigger arbitrary LLM conversations consuming API credits
2. Inject arbitrary message content into the orchestrator
3. Impersonate any Google Chat user by crafting `user.name` and `user.displayName` fields
4. Potentially invoke skills (including file write to Drive) via crafted messages

**Remediation**: Either (a) create a named pipeline in the router that includes the `GoogleChatAuth` plug and pipe the Google Chat webhook through it, or (b) add `plug AssistantWeb.Plugs.GoogleChatAuth` directly in the controller using a `plug` macro at the module level. Option (a) is preferred:

```elixir
pipeline :google_chat_auth do
  plug AssistantWeb.Plugs.GoogleChatAuth
end

scope "/webhooks", AssistantWeb do
  pipe_through [:api, :google_chat_auth]
  post "/google-chat", GoogleChatController, :event
end
```

---

## FINDING: HIGH -- Drive query injection via unsanitized folder ID

**Location**: `lib/assistant/skills/files/search.ex:93-96`
**Issue**: The `folder` flag (LLM-supplied) is inserted into the Drive query string using only single-quote escaping via `escape_query/1` (line 94: `'#{escape_query(folder)}' in parents`). The `escape_query` function (line 170-172) only escapes single quotes by replacing `'` with `\'`.

However, Drive query syntax supports operators like `and`, `or`, `not`, and comparison operators. An attacker (or a manipulated LLM) could supply a folder value containing `') or (name contains '` which, after escaping, still produces a valid but broadened query. Drive API query injection can expose files outside the intended scope.

The same pattern applies to the `query` parameter (line 80).

**Attack vector**: An LLM prompt injection attack could craft flag values like:
- `--folder "') or (trashed = true or name contains '"` to search trashed files
- `--query "') or (mimeType = 'application/vnd.google-apps.document"` to override type filtering

While the Drive API does not support truly destructive operations via search queries, the concern is **unauthorized data access** -- reading files the user did not intend to expose.

**Remediation**: Validate that `folder` contains only alphanumeric characters and hyphens/underscores (Drive folder IDs are opaque strings like `1a2b3c4d`). For `query`, consider using allowlisted patterns rather than passing raw LLM input into the Drive query string. At minimum, reject values containing the characters `(`, `)`, `=`, `<`, `>`.

---

## FINDING: HIGH -- Notification channel webhook URL not validated (SSRF potential)

**Location**: `lib/assistant/notifications/router.ex:166-177` and `lib/assistant/notifications/google_chat.ex:29-33`
**Issue**: The `decode_config/1` function (router.ex:228) passes the raw binary from the database `config` field directly as a URL to `Req.post/2` (google_chat.ex:32). There is no validation that this is a legitimate Google Chat webhook URL (which should match `https://chat.googleapis.com/v1/spaces/*/messages?key=*&token=*`).

If an attacker or a misconfigured admin inserts a malicious URL into the `notification_channels.config` column, the notification system becomes a Server-Side Request Forgery (SSRF) vector that will POST JSON payloads to arbitrary internal or external URLs.

Additionally, the `NotificationChannel` changeset (notification_channel.ex:30-35) performs no URL format validation on the `config` field.

**Attack vector**: If an attacker gains write access to the `notification_channels` table (SQL injection elsewhere, compromised admin interface, etc.), they can set `config` to an internal URL like `http://169.254.169.254/latest/meta-data/` to exfiltrate cloud metadata, or `http://localhost:4000/webhooks/...` for internal service interaction.

**Remediation**:
1. Add URL validation in the `NotificationChannel` changeset to ensure `config` matches an expected pattern (HTTPS only, specific domains for each channel type)
2. In `GoogleChat.send/3`, validate that the URL starts with `https://chat.googleapis.com/` before making the request
3. Consider using a URL allowlist approach at the application level

---

## FINDING: HIGH -- Notification channel config (webhook URLs) stored unencrypted

**Location**: `lib/assistant/schemas/notification_channel.ex:18-19`
**Issue**: The schema has a TODO comment on line 18: `"# TODO: encrypt with Cloak.Ecto before storing real credentials"`. The `config` field stores webhook URLs as plain binary. Google Chat incoming webhook URLs contain authentication tokens in the query string (`key=...&token=...`). These are effectively credentials -- anyone with the URL can post to the space.

The Cloak infrastructure already exists in the project (config/runtime.exs:106-115 configures `Assistant.Vault` with AES-GCM encryption), but it is not used for this field.

**Attack vector**: Database compromise (backup theft, SQL injection, unauthorized DB access) exposes all webhook URLs, allowing attackers to post arbitrary messages to Google Chat spaces and potentially impersonate the notification system.

**Remediation**: Use `Cloak.Ecto.Binary` (or the project's `Assistant.Vault`) for the `config` field. The infrastructure is already in place.

---

## FINDING: MEDIUM -- `String.to_existing_atom` on database-sourced severity values

**Location**: `lib/assistant/notifications/router.ex:153`
**Issue**: `String.to_existing_atom(rule.severity_min)` converts a database-sourced string to an atom. While `to_existing_atom` is safer than `to_atom` (it only converts strings to atoms that already exist in the BEAM atom table), the `@severity_levels` map keys (`:info`, `:warning`, `:error`, `:critical`) are indeed existing atoms. However, if the database contains a value not in the allowed set (due to a migration change or direct DB manipulation), this will raise an `ArgumentError`, crashing the entire `match_rules` function and causing the notification dispatch to fail silently.

**Attack vector**: Not a direct exploit, but a reliability concern. A corrupted or manipulated database value would crash notification routing. The changeset validates `severity_min` on insert, but values could be changed via direct DB access.

**Remediation**: Use a lookup map instead of atom conversion, or wrap in a try/rescue. Simplest fix: replace with `Map.get(@severity_levels, rule.severity_min)` where `@severity_levels` uses string keys instead of atom keys.

---

## FINDING: MEDIUM -- No clock skew tolerance in JWT exp validation

**Location**: `lib/assistant_web/plugs/google_chat_auth.ex:170-171`
**Issue**: The `validate_claims` function checks `claims["exp"] <= now` with exact equality. There is no tolerance for clock skew between Google's servers and the application server. Even minor clock drift could cause valid tokens to be rejected as expired, or conversely, expired tokens to be briefly accepted.

Industry standard for JWT validation is to allow a small leeway (typically 30-60 seconds) in both directions.

**Attack vector**: Not directly exploitable, but:
1. If the server clock is slightly ahead of Google, legitimate requests will be rejected (denial of service to the Google Chat integration)
2. If the server clock is slightly behind, expired tokens will be accepted for a brief window

**Remediation**: Add a configurable clock skew tolerance (e.g., 30 seconds):
```elixir
@clock_skew_seconds 30

not is_integer(claims["exp"]) or claims["exp"] + @clock_skew_seconds <= now ->
  {:error, :token_expired}
```

---

## FINDING: MEDIUM -- ETS cache table created with :public access

**Location**: `lib/assistant_web/plugs/google_chat_auth.ex:219`
**Issue**: The ETS table `:google_chat_certs_cache` is created with `:public` access, meaning any process in the BEAM VM can read and write to it. A compromised or buggy process could overwrite the cached certificates with attacker-controlled values, causing the JWT verification to accept forged tokens.

The same pattern exists for `:notification_dedup` in `lib/assistant/notifications/dedup.ex:25`.

**Attack vector**: If any process in the application is compromised (e.g., via a code injection vulnerability in the LLM processing pipeline), it could insert malicious certificates into the cache, allowing JWT forgery for subsequent requests.

**Remediation**: Use `:protected` access (the default) so only the owning process can write. The table would need to be owned by a long-lived process (a GenServer or the application start process). Consider moving the cert cache into a supervised GenServer.

---

## FINDING: MEDIUM -- Space name used directly in URL construction without validation

**Location**: `lib/assistant/integrations/google/chat.ex:60`
**Issue**: The `space_name` parameter is interpolated directly into the URL: `"#{@base_url}/#{space_name}/messages"`. The `space_name` originates from the incoming webhook payload (`space["name"]` in google_chat.ex:103) which is attacker-controlled when the auth plug is not applied (see CRITICAL finding).

Even with auth enabled, Google Chat space names follow the pattern `spaces/AAAA_BBBB`. There is no validation that the space_name conforms to this format.

**Attack vector**: A crafted space_name like `../../../v1/spaces/REAL_SPACE` or URL-encoded path traversal could redirect the API call to an unintended endpoint. Since the base URL is `https://chat.googleapis.com/v1`, path traversal could potentially access other Google APIs. The impact is limited by the service account's OAuth scopes, but the vector exists.

**Remediation**: Validate that `space_name` matches the expected format (`~r/^spaces\/[A-Za-z0-9_-]+$/`) before using it in URL construction.

---

## FINDING: LOW -- No rate limiting on Google Chat webhook endpoint

**Location**: `lib/assistant_web/router.ex:25`
**Issue**: The `/webhooks/google-chat` endpoint has no rate limiting. Each valid request spawns an async task that invokes the LLM orchestrator (potentially expensive API calls). Even with JWT verification properly applied, a compromised Google Chat space or a replay attack within the token validity window could generate excessive LLM API calls.

**Attack vector**: Rapid-fire webhook events (either from a compromised Google Chat workspace or, critically, from any unauthenticated source while the auth plug is not applied) could exhaust LLM API credits and overwhelm the application.

**Remediation**: Add rate limiting per space_id or user_id, either via a Plug or using the existing circuit breaker system. Consider leveraging `PlugAttack` or a simple ETS-based rate limiter.

---

## FINDING: LOW -- File IDs from LLM not validated before Drive API calls

**Location**: `lib/assistant/skills/files/read.ex:31`, `lib/assistant/skills/files/write.ex:29`
**Issue**: The `file_id` from `flags["id"]` (LLM-supplied) is passed directly to `Drive.read_file/2` and `Drive.get_file/1` without format validation. Google Drive file IDs are alphanumeric strings (e.g., `1a2b3c4d5e6f`). While the Drive API will reject invalid IDs with a 404, passing arbitrary strings to the API creates unnecessary noise and could potentially exploit undocumented API behaviors.

Similarly, `flags["folder"]` in write.ex:29 is used as `parent_id` without validation.

**Attack vector**: Low severity. LLM prompt injection could cause the assistant to attempt file operations on arbitrary IDs, but the service account's permissions scope the blast radius. The Drive API itself provides the authorization boundary.

**Remediation**: Add a regex validation for file/folder IDs (alphanumeric + hyphens/underscores, reasonable length) before passing to the Drive API. This is defense-in-depth.

---

## Areas with no issues found

**Auth module (`lib/assistant/integrations/google/auth.ex`)**: Clean wrapper around Goth. Credentials are not logged or exposed. The `configured?/0` function checks env without leaking values. Token strings are only passed by value, never logged. The `Logger.warning` on line 46 logs the reason but not the token itself.

**Credential handling in `config/runtime.exs`**: Credentials are loaded from environment variables, not hardcoded. The Google credentials parsing (lines 61-70) handles both inline JSON and file path modes correctly. No credentials are logged during configuration. The Cloak encryption key is properly Base64-decoded at config time.

**Google Chat REST client (`lib/assistant/integrations/google/chat.ex`)**: Message truncation at 32KB is appropriate. The auth token is fetched per-request (not cached insecurely). Error logging does not expose the token.

**Notification dedup (`lib/assistant/notifications/dedup.ex`)**: SHA-256 hashing for dedup keys is appropriate. The sweep mechanism prevents unbounded memory growth.

**Channel adapter (`lib/assistant/channels/google_chat.ex`)**: Normalization is defensive with fallbacks to empty strings/nil. Content is trimmed. Message IDs are generated with cryptographically strong random bytes.

---

## SECURITY REVIEW SUMMARY

| Severity | Count |
|----------|-------|
| Critical | 1 |
| High | 3 |
| Medium | 4 |
| Low | 2 |

**Overall assessment**: **FAIL**

The critical finding (JWT auth plug not wired into the router) means the Google Chat webhook endpoint is completely unauthenticated. This is a deployment-blocking issue that must be fixed before merge. The three HIGH findings (Drive query injection, SSRF via webhook URLs, unencrypted webhook credentials) represent significant but less immediately exploitable risks that should also be addressed.

### Blocking items (must fix before merge)

1. **[CRITICAL]** Wire `GoogleChatAuth` plug into the router pipeline for `/webhooks/google-chat`
2. **[HIGH]** Add webhook URL validation in `GoogleChat.send/3` and `NotificationChannel` changeset to prevent SSRF
3. **[HIGH]** Encrypt `notification_channels.config` field using existing Cloak infrastructure

### Recommended fixes (should fix before merge)

4. **[HIGH]** Validate/sanitize folder IDs and query strings in `files/search.ex` before Drive query construction
5. **[MEDIUM]** Add clock skew tolerance to JWT `exp` validation
6. **[MEDIUM]** Change ETS tables from `:public` to `:protected` access
7. **[MEDIUM]** Validate `space_name` format in `Google.Chat.send_message/3`
8. **[MEDIUM]** Use string keys in severity_levels map to avoid `String.to_existing_atom`
