# OpenRouter OAuth PKCE API Reference

> Prepared: 2026-02-21
> Sources: [OpenRouter OAuth PKCE Guide](https://openrouter.ai/docs/guides/overview/auth/oauth), [Code Exchange API](https://openrouter.ai/docs/api/api-reference/o-auth/exchange-auth-code-for-api-key), [Create Auth Code API](https://openrouter.ai/docs/api/api-reference/o-auth/create-auth-keys-code), [Authentication Reference](https://openrouter.ai/docs/api/reference/authentication), [Key Management](https://openrouter.ai/docs/api/api-reference/api-keys/delete-keys)

---

## Executive Summary

OpenRouter provides a PKCE-based OAuth flow that results in a **permanent API key** (not a short-lived access token). This is fundamentally different from standard OAuth2: there are no refresh tokens, no token expiry by default, and no traditional token revocation endpoint. Instead, the flow exchanges an authorization code for a long-lived API key that the user controls.

Key architectural differences from Google OAuth (existing pattern):

| Aspect | Google OAuth | OpenRouter OAuth |
|--------|-------------|-----------------|
| Result type | Short-lived access_token + refresh_token | Permanent API key |
| Expiry | Access token expires ~1hr; refresh token long-lived | Key never expires (unless `expires_at` set) |
| Refresh flow | POST to token endpoint with refresh_token | Not needed (key is permanent) |
| Revocation | POST to revoke endpoint | DELETE via Management API (requires management key) |
| PKCE | S256 code_challenge | S256 code_challenge (same) |
| Scopes | Granular OAuth scopes | No scopes (key has full account access) |
| State param | HMAC-signed anti-CSRF state | Not natively supported (use PKCE as CSRF protection) |
| App credentials | Client ID + client secret required | **None** -- public client flow, no app API key needed |

**Recommendation**: Store the OpenRouter API key encrypted in the database (like Google's refresh_token), but the lifecycle management is much simpler since there's no token refresh loop and no app credentials are required for the exchange.

---

## 1. OAuth PKCE Flow Overview

### Flow Diagram

```
User clicks "Connect OpenRouter"
    |
    v
Server generates code_verifier (random 43-128 char string)
Server computes code_challenge = base64url(sha256(code_verifier))
Server stores code_verifier in session/DB (encrypted)
    |
    v
Redirect user to:
  https://openrouter.ai/auth
    ?callback_url=https://yourapp.com/auth/openrouter/callback
    &code_challenge=<CODE_CHALLENGE>
    &code_challenge_method=S256
    |
    v
User logs in to OpenRouter, authorizes the app
    |
    v
OpenRouter redirects to:
  https://yourapp.com/auth/openrouter/callback?code=<AUTH_CODE>
    |
    v
Server POSTs to https://openrouter.ai/api/v1/auth/keys
  with { code, code_verifier, code_challenge_method }
    |
    v
Response: { "key": "sk-or-...", "user_id": "usr_..." }
    |
    v
Store key encrypted in database
```

---

## 2. Authorization Endpoint

### URL Format

```
https://openrouter.ai/auth?callback_url=<URL>&code_challenge=<CHALLENGE>&code_challenge_method=S256
```

### Query Parameters

| Parameter | Required | Type | Description |
|-----------|----------|------|-------------|
| `callback_url` | **Yes** | string (URL) | Redirect URL after authorization. Restrictions: HTTPS on ports 443 and 3000 only, OR `http://localhost:3000` for local dev |
| `code_challenge` | No (recommended) | string | PKCE challenge. For S256: `base64url(sha256(code_verifier))` |
| `code_challenge_method` | No | `"S256"` or `"plain"` | How `code_challenge` was derived. S256 is recommended |

**Notes**:
- There is **no `state` parameter** in the documented API. PKCE itself provides CSRF protection via the code_verifier binding.
- There is **no `scope` parameter**. The resulting API key has the user's full OpenRouter access.
- There is **no `site_name` or `site_url`** parameter documented for the `/auth` URL (these are sent as HTTP headers on API calls instead: `HTTP-Referer` and `X-Title`).
- The `callback_url` port restriction (443 and 3000 for HTTPS) is documented for the `POST /api/v1/auth/keys/code` endpoint. The browser-based `/auth` endpoint may have the same restrictions but this is not explicitly stated.

### PKCE Code Challenge Generation (S256)

```typescript
// Reference implementation from OpenRouter docs
async function generateCodeChallenge(codeVerifier: string): Promise<string> {
  const encoder = new TextEncoder();
  const data = encoder.encode(codeVerifier);
  const digest = await crypto.subtle.digest('SHA-256', data);
  return btoa(String.fromCharCode(...new Uint8Array(digest)))
    .replace(/\+/g, '-')
    .replace(/\//g, '_')
    .replace(/=+$/, '');
}
```

**Elixir equivalent**:
```elixir
code_verifier = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
code_challenge = :crypto.hash(:sha256, code_verifier) |> Base.url_encode64(padding: false)
```

---

## 3. Code Exchange Endpoint

### `POST https://openrouter.ai/api/v1/auth/keys`

Exchange the authorization code for a permanent API key.

### Request

**Headers**:
```
Content-Type: application/json
```

> **Correction (2026-02-21)**: The OpenAPI spec marks `Authorization: Bearer` as required, but the official OAuth PKCE guide's code example omits it entirely. The guide describes the flow as suitable for "local-first apps" that "can even work without a backend," confirming this is a **public client flow** -- no app API key is needed. The PKCE code/verifier pair is the sole authentication mechanism for this endpoint.

**Body** (JSON):
```json
{
  "code": "<AUTH_CODE_FROM_CALLBACK>",
  "code_verifier": "<ORIGINAL_CODE_VERIFIER>",
  "code_challenge_method": "S256"
}
```

| Field | Required | Type | Description |
|-------|----------|------|-------------|
| `code` | **Yes** | string | Authorization code from the callback URL query param |
| `code_verifier` | No* | string | Original code verifier (required if `code_challenge` was used in auth URL) |
| `code_challenge_method` | No* | `"S256"` or `"plain"` | Must match what was used in auth URL |

*Required if PKCE was used during authorization.

### Response

**Success (200)**:
```json
{
  "key": "sk-or-v1-abc123...",
  "user_id": "usr_abc123"
}
```

| Field | Type | Description |
|-------|------|-------------|
| `key` | string | The user's OpenRouter API key. This is the **only time** the full key is returned |
| `user_id` | string or null | The OpenRouter user ID associated with this key |

**Errors**:

| Status | Description |
|--------|-------------|
| 400 | Invalid request parameters or malformed input |
| 403 | Authentication successful but insufficient permissions |
| 500 | Unexpected server error |

---

## 4. Key Lifecycle

### Key Characteristics

- **Permanent by default**: The key does not expire unless `expires_at` was set during creation
- **No refresh tokens**: There is no refresh token mechanism. The key itself is the long-lived credential
- **User-controlled**: The user can manage/revoke the key from their OpenRouter dashboard at https://openrouter.ai/settings/keys
- **Spending limits**: Keys can have optional credit limits (daily/weekly/monthly reset)
- **One-time display**: The full key value is only returned once during creation. After that, only the hash is available

### Using the Key

Once obtained, use the key as a Bearer token for all OpenRouter API calls:

```
Authorization: Bearer sk-or-v1-abc123...
```

**Optional headers** (for OpenRouter analytics/rankings):

| Header | Purpose |
|--------|---------|
| `HTTP-Referer` | Your site URL (used for OpenRouter rankings) |
| `X-Title` | Your site/app name (used for OpenRouter rankings) |

---

## 5. Key Management (Server-Side)

These endpoints use a **Management API key** (separate from regular API keys). Management keys are created at https://openrouter.ai/settings/keys and can only perform administrative operations (not model completions).

> **For our use case**: We likely do NOT need management keys. The user's OAuth-generated key is stored encrypted and used directly. Revocation happens either:
> 1. User revokes from their OpenRouter dashboard
> 2. We delete our stored key from our database (effectively "disconnecting")
>
> Management API is documented here for completeness.

### Delete Key: `DELETE /api/v1/keys/{hash}`

```
Authorization: Bearer <MANAGEMENT_KEY>
DELETE https://openrouter.ai/api/v1/keys/{hash}
```

**Response (200)**:
```json
{ "deleted": true }
```

**Errors**: 401 (unauthorized), 404 (key not found), 429 (rate limited), 500 (server error)

### List Keys: `GET /api/v1/keys`

```
Authorization: Bearer <MANAGEMENT_KEY>
GET https://openrouter.ai/api/v1/keys?include_disabled=true&offset=0
```

**Response (200)**: Array of key objects with `hash`, `name`, `label`, `disabled`, `limit`, `usage`, `created_at`, `expires_at`, etc.

### Create Key: `POST /api/v1/keys`

```
Authorization: Bearer <MANAGEMENT_KEY>
Content-Type: application/json

{
  "name": "key-name",
  "limit": 10.00,
  "limit_reset": "monthly",
  "expires_at": "2026-12-31T00:00:00Z"
}
```

---

## 6. Alternative: Server-Side Auth Code Creation

### `POST https://openrouter.ai/api/v1/auth/keys/code`

This is an alternative to the browser-based `/auth` redirect. It creates an authorization code programmatically (server-to-server).

**Headers**:
```
Content-Type: application/json
Authorization: Bearer <YOUR_APP_API_KEY>
```

**Body**:
```json
{
  "callback_url": "https://yourapp.com/auth/openrouter/callback",
  "code_challenge": "<CODE_CHALLENGE>",
  "code_challenge_method": "S256",
  "limit": 50.00,
  "expires_at": "2026-12-31T00:00:00Z",
  "key_label": "My App - User 123",
  "usage_limit_type": "monthly"
}
```

| Field | Required | Type | Description |
|-------|----------|------|-------------|
| `callback_url` | **Yes** | string (URI) | Redirect URL. HTTPS on ports 443 and 3000 only |
| `code_challenge` | No | string | PKCE code challenge |
| `code_challenge_method` | No | `"S256"` or `"plain"` | Challenge derivation method |
| `limit` | No | number | Credit allowance for the generated key (USD) |
| `expires_at` | No | string (ISO 8601) or null | Key expiration timestamp |
| `key_label` | No | string | Custom name for the key (defaults to app name) |
| `usage_limit_type` | No | string | Reset interval: `"daily"`, `"weekly"`, or `"monthly"` |

**Response (200)**:
```json
{
  "data": {
    "id": "auth_code_string",
    "app_id": "numeric_app_id",
    "created_at": "2026-02-21T00:00:00Z"
  }
}
```

> **Note**: This endpoint is for server-to-server flows where the app creates the auth code on behalf of the user. For our browser-based connect button, the standard `/auth` redirect flow (Section 2) is the right choice.

---

## 7. Security Considerations

### PKCE as CSRF Protection

Since OpenRouter does not support a `state` parameter, the PKCE `code_verifier` serves as the primary CSRF protection mechanism. The server must:
1. Generate a unique `code_verifier` per authorization attempt
2. Store it server-side (session or encrypted DB column) before redirecting
3. Verify it matches when exchanging the code

This is equivalent to the CSRF protection that `state` provides in standard OAuth2.

### Key Storage

The API key is a permanent credential equivalent to a password. It must be:
- Stored encrypted at rest (use `Encrypted.Binary` like existing Google tokens)
- Never logged or exposed in error messages
- Transmitted only over HTTPS

### Key Exposure

OpenRouter partners with GitHub secret scanning. If a key is detected in a public repo, the user receives an email notification. Compromised keys should be deleted immediately at https://openrouter.ai/settings/keys.

### No Scope Limitation

Unlike Google OAuth which grants specific scopes, an OpenRouter API key has full access to the user's account capabilities (model completions, usage tracking, etc.). There is no way to request reduced permissions.

---

## 8. Implementation Recommendations

### For the Phoenix/LiveView App

1. **Authorization URL**: Use the browser-based `/auth` redirect (Section 2), not the server-side `create-auth-keys-code` endpoint.

2. **PKCE**: Always use S256. Generate `code_verifier` server-side, compute `code_challenge`, store `code_verifier` encrypted in DB before redirect.

3. **State/CSRF**: Since OpenRouter doesn't support `state`, use the PKCE `code_verifier` binding as CSRF protection. Optionally, also store a session-bound nonce and embed it in the `callback_url` path or query (e.g., `?nonce=abc123`) for defense-in-depth.

4. **Key Storage**: Store the returned `key` in an encrypted DB column (`Encrypted.Binary`). Store `user_id` as a plain string for reference.

5. **No Refresh Logic**: Unlike Google OAuth, there is no token refresh cycle. The key is permanent. The connect flow is one-time per user.

6. **Disconnect**: To "disconnect" OpenRouter, simply delete the stored key from the database. The key remains valid on OpenRouter's side (user can revoke from their dashboard).

7. **Error Handling**:
   - 400 from code exchange: Invalid/expired code, or PKCE mismatch
   - 403 from code exchange: Invalid code or code_verifier
   - Key stops working later: User deleted it from OpenRouter dashboard

8. **No App API Key Required**: The code exchange endpoint is a public client endpoint. No `Authorization` header or server-side `OPENROUTER_API_KEY` env var is needed. The PKCE code/verifier pair is the sole authentication mechanism. This enables zero-config self-hosting.

---

## 9. Compatibility Matrix

| Component | Version/Requirement |
|-----------|-------------------|
| PKCE methods | `S256` (recommended), `plain` |
| Callback URL protocols | HTTPS (ports 443, 3000), `http://localhost:3000` for dev |
| API key format | `sk-or-v1-...` prefix |
| Auth endpoint | `https://openrouter.ai/auth` (browser redirect) |
| Code exchange endpoint | `POST https://openrouter.ai/api/v1/auth/keys` |
| Key management endpoints | `GET/POST/DELETE /api/v1/keys` (Management key required) |
| TypeScript SDK | Beta (available but not required) |
| Python SDK | Available (not required for Elixir backend) |

---

## 10. Resource Links

| Resource | URL |
|----------|-----|
| OAuth PKCE Guide | https://openrouter.ai/docs/guides/overview/auth/oauth |
| Exchange Auth Code API | https://openrouter.ai/docs/api/api-reference/o-auth/exchange-auth-code-for-api-key |
| Create Auth Code API | https://openrouter.ai/docs/api/api-reference/o-auth/create-auth-keys-code |
| Authentication Reference | https://openrouter.ai/docs/api/reference/authentication |
| Key Management (Provisioning) | https://openrouter.ai/docs/guides/overview/auth/provisioning-api-keys |
| Delete Key API | https://openrouter.ai/docs/api/api-reference/api-keys/delete-keys |
| Create Key API | https://openrouter.ai/docs/api/api-reference/api-keys/create-keys |
| List Keys API | https://openrouter.ai/docs/api/api-reference/api-keys/list |
| Key Rotation Guide | https://openrouter.ai/docs/guides/guides/api-key-rotation |
| TypeScript SDK OAuth | https://openrouter.ai/docs/sdks/typescript/api-reference/oauth |
| Python SDK OAuth | https://openrouter.ai/docs/sdks/python/api-reference/oauth |
