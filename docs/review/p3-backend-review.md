# Phase 3 Backend Code Review

**Reviewer**: pact-backend-coder
**Date**: 2026-02-18
**Scope**: Channels, integrations, notifications — all new/modified backend files in Phase 3

---

## BLOCKING Issues

### B1. GoogleChatAuth Plug Not Wired Into Router [SECURITY]

**File**: `lib/assistant_web/router.ex:21-26`
**Severity**: BLOCKING

The `AssistantWeb.Plugs.GoogleChatAuth` plug is defined in `lib/assistant_web/plugs/google_chat_auth.ex` but is **never applied** to any route or pipeline. The `/webhooks/google-chat` route only passes through the `:api` pipeline, which only runs `:accepts`. The controller's module doc at line 20 states "GoogleChatAuth plug verifies the JWT" but this plug is not actually invoked anywhere.

**Impact**: Any HTTP client can POST to `/webhooks/google-chat` and trigger orchestrator processing without any authentication. This bypasses all JWT verification logic.

**Fix**: Either add the plug to a dedicated pipeline or apply it directly on the route scope:

```elixir
pipeline :google_chat_auth do
  plug AssistantWeb.Plugs.GoogleChatAuth
end

scope "/webhooks", AssistantWeb do
  pipe_through [:api, :google_chat_auth]
  post "/google-chat", GoogleChatController, :event
end
```

### B2. `ensure_engine_started` Error Not Propagated — Orchestrator Proceeds on Failure

**File**: `lib/assistant_web/controllers/google_chat_controller.ex:99-105`
**Severity**: BLOCKING

In `process_and_reply/1`, the return value of `ensure_engine_started/2` is ignored:

```elixir
ensure_engine_started(conversation_id, message)   # line 102 — return value dropped

case Engine.send_message(conversation_id, message.content) do  # line 105 — crashes if no engine
```

If `ensure_engine_started` returns `{:error, reason}` (e.g., line 199), the code proceeds to call `Engine.send_message` on a non-existent engine, which will crash the Task with an unclear error. The outer rescue at line 136 catches it but the root cause is obscured.

**Fix**: Pattern-match on `ensure_engine_started` and return early on error:

```elixir
case ensure_engine_started(conversation_id, message) do
  :ok -> # proceed to Engine.send_message
  {:error, reason} -> # send error reply to user
end
```

### B3. `String.to_existing_atom` on DB Value — Possible `ArgumentError`

**File**: `lib/assistant/notifications/router.ex:153`
**Severity**: BLOCKING

```elixir
rule_level = Map.get(@severity_levels, String.to_existing_atom(rule.severity_min), 0)
```

`rule.severity_min` comes from the database. If an operator inserts an unexpected severity string (e.g., `"debug"`), `String.to_existing_atom/1` raises `ArgumentError` because the atom does not exist. This crashes the `handle_cast` and the entire Router GenServer restarts, losing the current dedup state.

**Fix**: Use `String.to_atom/1` (the set is bounded by the `@severities` validation on the schema) or, more defensively, catch the error and fall back to 0.

---

## MINOR Issues

### M1. X.509 Certificate Parsing Uses Record Element Indexing

**File**: `lib/assistant_web/plugs/google_chat_auth.ex:134-138`
**Severity**: MINOR (fragile but functional)

```elixir
cert = :public_key.pkix_decode_cert(der, :otp)
public_key = elem(elem(cert, 1), 7)
rsa_key = elem(public_key, 1)
```

This uses positional `elem/2` on OTP records. The positions (1, 7, 1) are correct for the current OTP version's `OTPCertificate` and `OTPSubjectPublicKeyInfo` records, but they are fragile if the record structure ever changes. Prefer using Erlang record accessors or the `Record` module. The `try/rescue` at line 140 makes this safe at runtime, but a quiet failure here would be very hard to debug.

### M2. ETS Table Race in `ensure_ets_table`

**File**: `lib/assistant_web/plugs/google_chat_auth.ex:216-228`
**Severity**: MINOR

The check-then-create pattern (`ets.whereis` then `ets.new`) has a TOCTOU window where another process could create the table between the check and the create. The rescue on `ArgumentError` handles this, which is correct. However, the owner of this ETS table is whichever process first calls the plug, not a long-lived process. If that owner process dies (e.g., a cowboy process terminates), the table is destroyed and the next request must re-fetch certificates.

Consider moving the ETS table creation into `application.ex` (via a named persistent table) or into a dedicated GenServer so the table survives request process crashes.

### M3. `truncate_message` Mixes Bytes and Characters

**File**: `lib/assistant/integrations/google/chat.ex:108-114`
**Severity**: MINOR

The guard uses `byte_size(text)` to check the limit (correct, since the Google Chat API limit is in bytes), but `String.slice/3` on line 113 slices by **character count**, not bytes. For UTF-8 messages with multi-byte characters, `String.slice(text, 0, max)` may still exceed `max` bytes. In practice the 50-byte margin provides buffer, but for messages heavy in CJK or emoji this could still exceed the limit.

**Fix**: Use `:binary.part(text, 0, max)` and then re-validate UTF-8 boundary, or use `String.slice` with a byte-aware helper.

### M4. `read_file` Makes Two API Calls for Metadata

**File**: `lib/assistant/skills/files/read.ex:77-85`

`read_and_format/3` calls `drive.read_file(file_id)` which internally calls `get_file(file_id)` for metadata, and then `build_header/2` calls `drive.get_file(file_id)` again. This doubles the metadata API calls.

**Fix**: Have `read_file` return the metadata alongside the content, or pass the already-fetched metadata into `build_header`.

### M5. Notification Channel `config` Not Encrypted

**File**: `lib/assistant/schemas/notification_channel.ex:19`

The schema stores `config` (which contains webhook URLs) as plain `:binary`. The TODO on line 18 notes Cloak.Ecto encryption is planned. While webhook URLs are not secrets in the traditional sense, they are bearer tokens — anyone with the URL can post to the space. This should be tracked as a P2 item.

### M6. `Dedup.sweep/0` Is Not Atomic

**File**: `lib/assistant/notifications/dedup.ex:61-72`

The sweep selects expired keys and then deletes them one by one. Between the select and the delete, a new record could be inserted with the same key and then immediately deleted. This is a very narrow window and unlikely in practice, but using `:ets.select_delete/2` would be both more correct and more efficient.

### M7. Notification Router `load_rules` Queries DB in `init`

**File**: `lib/assistant/notifications/router.ex:113-131`

The `init/1` callback queries the database. If the Repo is not yet started (depends on supervision tree ordering) or the query is slow, this delays startup. The rescue on line 129 handles this gracefully by falling back to `[]`, but the rules are then never reloaded — so if the DB was temporarily unavailable at startup, the router permanently operates in fallback mode until restarted.

Consider adding a periodic reload (e.g., every 5 minutes) or loading rules lazily on first notification.

### M8. `escape_query` in files.search Is Incomplete

**File**: `lib/assistant/skills/files/search.ex:170-172`

```elixir
defp escape_query(str) do
  String.replace(str, "'", "\\'")
end
```

The Google Drive query language also treats backslashes as escape characters. A query string containing `\` is not escaped, which could produce malformed queries. Additionally, the `folder` value on line 94 is user-provided and directly interpolated into the Drive query string with only single-quote escaping.

While this cannot cause SQL injection (it goes to the Drive API), it can cause confusing API errors or unexpected search results.

---

## FUTURE Considerations

### F1. Webhook URL Validation in Notification Dispatch

`dispatch_to_channel/2` at `router.ex:166` passes `config` directly to `GoogleChat.send/2` as a URL without validating it is a valid HTTPS URL. A malformed config value would produce a confusing Req error. Consider URL validation at the schema level.

### F2. Rate Limiting for the Google Chat Webhook Endpoint

There is no rate limiting on the `/webhooks/google-chat` endpoint beyond the JWT verification (once B1 is fixed). While Google Chat itself rate-limits outgoing webhooks, a compromised JWT or replay attack could overwhelm the orchestrator. Consider adding plug-level rate limiting.

### F3. Adapter Behaviour `send_reply` Return Type Inconsistency

The `Adapter` behaviour specifies `send_reply` returning `:ok | {:error, term()}`, and the `GoogleChat` adapter correctly wraps the `{:ok, _}` response from `ChatClient` into `:ok`. However, the `ChatClient.send_message` function returns `{:ok, response_body}` (the body is lost). If callers ever need the response body (e.g., for message ID tracking), this information is discarded at the adapter layer.

### F4. Hard-Coded `mode: :multi_agent` in Controller

`google_chat_controller.ex:168` hard-codes `mode: :multi_agent` for all Google Chat conversations. This should be configurable per space or use case.

### F5. Drive API `create_file` Lacks Input Size Validation

`write.ex` passes user-provided content directly to `Drive.create_file` without checking content size. Very large content strings could cause memory issues or API errors. Consider adding a size guard.

---

## Summary

| Category | Count | IDs |
|----------|-------|-----|
| Blocking | 3 | B1, B2, B3 |
| Minor | 8 | M1-M8 |
| Future | 5 | F1-F5 |

**Overall Assessment**: The code is well-structured with clean separation of concerns — the adapter pattern, integration wrappers, and notification pipeline are all well-designed. Documentation headers and typespecs are thorough. However, B1 (auth plug not wired) is a critical security gap that must be fixed before merge. B2 and B3 are runtime crash risks that should also be resolved.

**Strengths**:
- Clean adapter behaviour pattern with proper protocol separation
- Consistent `{:ok, _} | {:error, _}` return tuples across all modules
- Good use of structured logging with context metadata throughout
- Proper crash isolation via `Task.Supervisor` for async processing
- Drive API wrapper normalizes GoogleApi structs into plain maps (good boundary)
- ETS dedup with periodic sweep is a solid approach for notification throttling

**Key Risk**: B1 means the webhook endpoint is currently unauthenticated. This is the single most important fix.
