# Phase 3 Architecture Review

**Reviewer**: pact-architect
**Date**: 2026-02-18
**PR**: #8 (Channels, Integrations, Notifications)
**Verdict**: APPROVE with required fixes (2 blocking, 7 minor)

---

## Blocking Issues

### B1. GoogleChatAuth plug is not wired into the router

**Files**: `lib/assistant_web/router.ex`, `lib/assistant_web/plugs/google_chat_auth.ex`

The `GoogleChatAuth` plug exists and is well-implemented (JWT verification, cert caching, claim validation), but it is **never applied** in the router. The `/webhooks/google-chat` route goes through the `:api` pipeline only, which just calls `plug :accepts, ["json"]`. The controller comments at lines 4, 20, and 46 all claim "GoogleChatAuth plug verifies the JWT" and "applied in the router" -- but this is false.

**Impact**: The Google Chat webhook endpoint is completely unauthenticated. Any HTTP client can POST arbitrary payloads to `/webhooks/google-chat` and trigger orchestrator processing, consuming LLM tokens and potentially manipulating conversations.

**Fix**: Either add a dedicated pipeline or use `plug` directly in a scoped block:

```elixir
scope "/webhooks", AssistantWeb do
  pipe_through :api

  # Google Chat — JWT verification required
  scope "/" do
    plug AssistantWeb.Plugs.GoogleChatAuth
    post "/google-chat", GoogleChatController, :event
  end

  post "/telegram", WebhookController, :telegram
end
```

Alternatively, apply the plug at the controller level with `plug AssistantWeb.Plugs.GoogleChatAuth` in the controller module.

### B2. `ensure_engine_started/2` error return is silently discarded

**File**: `lib/assistant_web/controllers/google_chat_controller.ex:102`

```elixir
ensure_engine_started(conversation_id, message)
# ^^ return value ignored -- proceeds to Engine.send_message regardless
```

When `DynamicSupervisor.start_child` fails (line 177-199), the function returns `{:error, reason}`, but `process_and_reply/1` ignores this and calls `Engine.send_message/2` anyway. This will crash with `{:noproc, ...}` because the Engine GenServer was never started, triggering the rescue block which logs a generic error and sends a user-facing error message -- but the root cause (engine start failure) is masked.

**Fix**: Pattern-match on `ensure_engine_started/2` return and short-circuit with an error reply if engine start fails:

```elixir
case ensure_engine_started(conversation_id, message) do
  :ok -> # proceed with Engine.send_message
  {:error, reason} -> # send error reply to user, log root cause
end
```

---

## Minor Issues

### M1. `String.to_existing_atom/1` crash risk in notification Router

**File**: `lib/assistant/notifications/router.ex:153`

```elixir
rule_level = Map.get(@severity_levels, String.to_existing_atom(rule.severity_min), 0)
```

If the database contains a `severity_min` value that has never been used as an atom in the BEAM (e.g., due to a manual DB insert or migration data), `String.to_existing_atom/1` will raise `ArgumentError`. Since this runs inside a `handle_cast`, it will crash the Router GenServer.

**Fix**: Use `String.to_atom/1` (the values are constrained by `validate_inclusion` in the schema changeset, so the input domain is bounded) or keep a string-keyed severity map and skip atom conversion entirely.

### M2. Chat API `truncate_message/1` uses `String.slice/3` on byte-limited text

**File**: `lib/assistant/integrations/google/chat.ex:108-115`

The guard checks `byte_size(text) <= @max_message_bytes`, but the truncation uses `String.slice(text, 0, max)` which operates on grapheme clusters, not bytes. For multi-byte UTF-8 content, `String.slice(text, 0, @max_message_bytes - 50)` could still exceed the byte limit. The appended `"\n\n[Message truncated due to length limit]"` is also not accounted for in the byte budget correctly.

**Fix**: Use `binary_part/3` for byte-accurate truncation, then trim to the last valid UTF-8 boundary, or use `:binary.part/3` with a UTF-8 safe trim.

### M3. ETS table ownership in GoogleChatAuth plug

**File**: `lib/assistant_web/plugs/google_chat_auth.ex:216-228`

The `ensure_ets_table/0` function creates a `:public` ETS table from whatever process first handles a request. If that process (a cowboy handler process) exits, the ETS table is destroyed because ETS tables are owned by their creator. The next request will recreate it but lose the cached certificates, defeating the 1-hour TTL cache.

**Fix**: Either:
1. Create the table in `application.ex` where it will be owned by a long-lived process, or
2. Use an `:ets.new` with `{:heir, ...}` option, or
3. Use a dedicated GenServer or Agent to own the table (simplest: add it to the supervision tree).

### M4. Notification Router loads rules only at init, never refreshes

**File**: `lib/assistant/notifications/router.ex:68`

Rules are loaded from the database once during `init/1` and stored in GenServer state. Adding, modifying, or disabling a rule in the database has no effect until the Router process is restarted. There is no `handle_call` or `handle_info` for reloading rules.

**Fix**: Add a `reload_rules/0` public API (a `GenServer.call` that re-reads the DB and updates state), or periodically refresh rules on a timer similar to the dedup sweep. Alternatively, document this as a known limitation and provide a manual reload mechanism.

### M5. Files.Read makes two Drive API calls for every read

**File**: `lib/assistant/skills/files/read.ex:43-75, 77-86`

`read_and_format/3` calls `drive.read_file(file_id, opts)` which internally calls `get_file(file_id)` to check the MIME type (line 147 of drive.ex). Then `build_header/2` calls `drive.get_file(file_id)` again. This results in two `get_file` API calls per read operation.

**Fix**: Have `read_file/2` return the metadata alongside the content (or cache the metadata from the first call), and pass it to `build_header` instead of re-fetching.

### M6. Hardcoded `user_id: "dev-user"` in Memory.Agent supervision

**File**: `lib/assistant/application.ex:45`

```elixir
{Assistant.Memory.Agent, user_id: "dev-user"},
```

This was flagged in Phase 1 review but remains. With Google Chat now providing real user identities (`message.user_id`), the singleton Memory.Agent with a hardcoded user creates a mismatch -- all conversations from different Google Chat users share the same memory agent identity.

**Fix**: This is a known limitation for now, but should be addressed before multi-user deployment. Document the constraint clearly.

### M7. `process_and_reply/1` rescue is too broad

**File**: `lib/assistant_web/controllers/google_chat_controller.ex:136-142`

```elixir
rescue
  error ->
    Logger.error(...)
```

The bare `rescue error ->` catches all exceptions but silently swallows them. In production, this means any unexpected crash in async processing (e.g., a `FunctionClauseError` from bad data) produces only a log line -- no notification to the user via Google Chat, no telemetry event, no process exit signal to the supervisor.

**Fix**: At minimum, attempt to send an error reply to the user in the rescue block (as is done in the `{:error, reason}` branch). Consider whether swallowing the exception is correct or whether the Task should be allowed to crash (the Task.Supervisor handles crashes).

---

## Architectural Assessment

### 1. Channel Adapter Pattern

**Verdict**: Well-designed.

The `Adapter` behaviour (`adapter.ex`) defines a clean three-callback contract: `normalize/1`, `send_reply/3`, `channel_name/0`. The `Message` struct (`message.ex`) provides a comprehensive normalized representation with all the fields needed for cross-channel operation. The GoogleChat implementation is thorough with proper handling of MESSAGE, APP_COMMAND, ADDED_TO_SPACE, and REMOVED_FROM_SPACE events.

The separation between the channel adapter (normalization + reply routing) and the integration client (HTTP calls to Google APIs) is correct. `Channels.GoogleChat` delegates to `Integrations.Google.Chat` for actual HTTP work.

One design observation: the `Message` struct has Google Chat-specific fields like `argument_text` and `slash_command` that may not map to other channels. This is acceptable for now -- these fields are optional and can be nil for channels that don't support them.

### 2. Async Reply Pattern (30-second timeout handling)

**Verdict**: Architecturally sound with caveats.

The pattern is correct: return `{"text": "Processing..."}` synchronously within Google Chat's 30-second timeout, then spawn an async task to process via the orchestrator and reply via the REST API. Using `Task.Supervisor.start_child/2` with the existing `Skills.TaskSupervisor` provides crash isolation.

**Caveats**:
- The `ensure_engine_started` check-then-start pattern has a TOCTOU race, but this is handled correctly with the `{:error, {:already_started, _pid}}` catch at line 189.
- There is no timeout on the async task itself. `Engine.send_message` has a 120-second timeout (line 102 of engine.ex), but if the Engine hangs without responding, the Task will block indefinitely. Since it's under Task.Supervisor with `:temporary` restart (default), it won't be restarted, but it will leak.
- There is no mechanism to notify the user if the async task crashes silently (addressed in M7).

### 3. Supervision Tree

**Verdict**: Correctly structured.

The supervision tree ordering is appropriate:
1. Config.Loader, PromptLoader (infrastructure)
2. Repo, DNS, PubSub (core services)
3. Goth (conditional -- well-gated by `maybe_goth/0`)
4. Oban (job processing)
5. Skills system (TaskSupervisor, Registry, Watcher)
6. Orchestrator registries and ConversationSupervisor
7. Memory systems
8. Notifications.Router
9. Web endpoint (last)

The Goth conditional start via `maybe_goth/0` is a good pattern -- allows dev environments without Google credentials to function. The notification Router is placed after the memory system (correct -- it doesn't depend on it) and before the endpoint (correct -- notifications should be available when webhooks arrive).

### 4. Notification System

**Verdict**: Well-structured with minor issues (M1, M4).

The three-module decomposition is clean:
- **Router** (GenServer): orchestrates flow -- dedup check, rule matching, channel dispatch
- **Dedup** (ETS): stateless dedup logic with monotonic time tracking and periodic sweep
- **GoogleChat** (sender): HTTP POST to incoming webhooks

The dedup implementation is sound: SHA-256 hash of message content prevents sensitive data in ETS keys, 5-minute window, periodic sweep. The severity-level threshold matching with optional component filter is flexible.

The fallback behavior (env var webhook when no DB rules exist) is a practical default for early deployment.

### 5. Separation of Concerns

**Verdict**: Clean layering.

The architecture follows a clear layered structure:

```
Web Layer:    Router -> Plug (auth) -> Controller
                                          |
Channel:      GoogleChat adapter (normalize + send_reply)
                    |                  |
Integration:  Google.Auth    Google.Chat (REST client)
                    |
Infrastructure: Goth (OAuth2 token management)
```

For file skills:
```
Skill Layer:  Files.Search / Files.Read / Files.Write
                    |
Integration:  Google.Drive (API wrapper)
                    |
Infrastructure: Google.Auth -> Goth
```

For notifications:
```
Notifications.Router (GenServer) -> Dedup (ETS)
        |                              |
        v                              v
  match rules (DB)              sweep expired
        |
        v
  GoogleChat sender (HTTP)
```

Each layer has a single responsibility. The Google.Auth module centralizes credential management for all Google API consumers. The Drive client normalizes GoogleApi structs into plain maps, shielding skill handlers from library internals.

### 6. Missing Items

The following are absent from Phase 3 but would be expected for a production deployment:

1. **Rate limiting on the webhook endpoint** -- Without the auth plug (B1), this is moot, but even with auth, there should be rate limiting to prevent abuse from legitimate but misbehaving clients.

2. **Telemetry/metrics instrumentation** -- No `:telemetry.execute` calls anywhere in the Phase 3 code. The async reply path, notification dispatch, and Drive API calls are all candidates for timing metrics.

3. **Notification system integration with existing components** -- The Router exists but nothing calls `Router.notify/4` yet. The circuit breaker, orchestrator error paths, and LLM client should be wired to emit notifications. This may be intentionally deferred.

4. **Graceful handling of Goth unavailability** -- If Goth is not started (no credentials configured), calls to `Google.Auth.token/0` will fail with `{:error, ...}`. The Drive client and Chat client handle this gracefully (propagate error tuples). However, the GoogleChat controller's `process_and_reply/1` will hit `ChatClient.send_message` failure paths if Goth is down mid-operation. Consider a circuit breaker or feature gate check before spawning async processing.

5. **No admin API for notification rules** -- Rules must be managed via direct DB manipulation. A CRUD endpoint or admin console for managing notification channels and rules would be needed before multi-user deployment.

---

## Future Considerations

1. **Multi-tenant memory isolation**: As noted in M6, the singleton Memory.Agent needs to evolve to per-user or per-workspace memory when supporting multiple Google Chat users.

2. **Channel adapter registry**: Currently GoogleChat is the only adapter. When Telegram is added (stub route exists), consider a registry pattern mapping channel atoms to adapter modules, avoiding hardcoded dispatching.

3. **Notification channel extensibility**: The Router's `dispatch_to_channel/2` uses pattern matching on `%{type: "google_chat_webhook"}`. Adding new channel types requires modifying this function. Consider a behaviour-based dispatch similar to channel adapters.

4. **Drive API pagination**: `list_files/2` supports `pageToken` but the files.search skill handler doesn't implement pagination. For large result sets, users only get the first page.

5. **Conversation lifecycle management**: The GoogleChat controller starts conversation engines with `:temporary` restart strategy, but there's no mechanism to stop idle engines. Over time, this could accumulate GenServer processes for abandoned conversations.

---

## Summary

Phase 3 delivers a well-architected channel adapter system with clean separation between web layer, channel abstraction, integration clients, and skill handlers. The notification system is a solid foundation with appropriate dedup and rule-matching logic.

The two blocking issues (B1: unauthenticated webhook, B2: ignored engine start error) must be fixed before merge. The minor issues are straightforward improvements that can be addressed in this PR or tracked for follow-up.

| Category | Count |
|----------|-------|
| Blocking | 2 |
| Minor | 7 |
| Future | 5 |
