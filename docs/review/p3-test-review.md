# Phase 3 Test Review — PR #8

**Reviewer**: PACT Test Engineer (p3-test)
**Date**: 2026-02-18
**Risk Tier**: HIGH (Google Chat JWT auth, webhook ingress, notification routing, Google Drive skill handlers)

---

## 1. Test Execution Summary

**Environment**: Tests could not execute due to `:telegex` dependency compilation failure. The `telegex` library references `Plug.Router` at compile time, but the `:plug_router` dependency is unavailable in the current dep tree (`:plug` provides `Plug.Conn` but not `Plug.Router` without Phoenix Router or plug_cowboy). This is a pre-existing build issue unrelated to Phase 3 code.

| Metric | Value |
|--------|-------|
| Total tests run | 0 (compilation blocked) |
| Compilation error | `:telegex` dep fails — `Plug.Router is not loaded` |
| Phase 3 test files | **0** — No test files exist for any Phase 3 module |

### Compilation Issue

```
error: module Plug.Router is not loaded and could not be found
  lib/telegex/hook/server.ex:5: Telegex.Hook.Server (module)
```

This blocks `mix test --no-start` entirely. The `:telegex` dependency (Telegram bot library) is unrelated to Phase 3 work but prevents compilation of the full project.

---

## 2. Phase 3 Module Inventory

Phase 3 introduces **15 new source files** across 4 domains with **0 test files**:

| Domain | Files | Total LOC | Tests |
|--------|-------|-----------|-------|
| Channels (adapter layer) | `adapter.ex`, `message.ex`, `google_chat.ex` | ~237 | 0 |
| Integrations (Google APIs) | `google/auth.ex`, `google/chat.ex`, `google/drive.ex` | ~409 | 0 |
| Notifications | `dedup.ex`, `google_chat.ex`, `router.ex` | ~312 | 0 |
| Skills/Files | `search.ex`, `read.ex`, `write.ex` | ~340 | 0 |
| Web (controller + plug) | `google_chat_controller.ex`, `google_chat_auth.ex` | ~441 | 0 |
| **Total** | **15 files** | **~1,739** | **0** |

---

## 3. Coverage Gaps by Priority

### 3.1 CRITICAL — GoogleChatAuth JWT Plug (229 lines, 0 tests)

**File**: `lib/assistant_web/plugs/google_chat_auth.ex`

This is the **security gateway** for all Google Chat webhook traffic. Zero test coverage on any path.

**Untested critical paths**:
- `extract_bearer_token/1`: missing header -> `{:error, :missing_bearer_token}`, malformed header (no "Bearer " prefix)
- `extract_kid/1`: valid JWT header with kid, missing kid, malformed token (rescue path)
- `validate_claims/2`: wrong issuer, wrong audience, expired token, missing `exp` claim, non-integer `exp`
- `verify_signature/2`: valid RS256 signature, invalid signature, rescue on malformed input
- `pem_to_jwk/1`: valid X.509 PEM -> JWK, malformed PEM (rescue path)
- `get_cached_certs/0`: cold cache (fetch), warm cache (hit), expired cache (refetch), fetch failure
- `ensure_ets_table/0`: table creation, already-exists race condition
- Full plug `call/2` flow: valid token -> assigns claims, any failure -> 401 + halt

**Testability**: MODERATE. The `validate_claims/2` and `extract_kid/1` functions are private but have pure logic that could be tested through the public `call/2` interface with a mock conn. Certificate fetching requires mocking `Req.get`. JOSE JWT operations can be tested with self-signed test keys.

**Risk**: Any bug here allows unauthenticated requests to reach the controller. This is the single authentication boundary for the Google Chat channel.

### 3.2 CRITICAL — Router wiring gap: GoogleChatAuth plug NOT applied

**File**: `lib/assistant_web/router.ex:21-26`

**Finding**: The `GoogleChatAuth` plug is defined but **never applied** in the router. The `/webhooks/google-chat` route only goes through the `:api` pipeline (which only does `accepts: ["json"]`). There is no authentication middleware on the Google Chat webhook endpoint.

```elixir
# Current router — NO auth plug applied
scope "/webhooks", AssistantWeb do
  pipe_through :api
  post "/google-chat", GoogleChatController, :event
end
```

The controller's moduledoc says "JWT verification is performed by the GoogleChatAuth plug (applied in the router)" but this is not actually true. The plug exists but is not wired in.

**Risk**: Without the auth plug, ANY unauthenticated POST to `/webhooks/google-chat` will be processed by the controller. This is a **security vulnerability** — the endpoint is effectively open.

### 3.3 HIGH — Channels.GoogleChat normalize/1 (184 lines, 0 tests)

**File**: `lib/assistant/channels/google_chat.ex`

**Untested critical paths**:
- `normalize/1` with `MESSAGE` event: full field extraction (message, user, space, thread, content, slash command, attachments)
- `normalize/1` with `APP_COMMAND` event: same as MESSAGE (code reuse path)
- `normalize/1` with `ADDED_TO_SPACE` event: space metadata, user info, empty content
- `normalize/1` with `REMOVED_FROM_SPACE`: returns `{:error, :ignored}`
- `normalize/1` with unknown event type: returns `{:error, :ignored}`
- `normalize/1` with missing nested fields (nil message, nil user, nil space)
- `extract_slash_command/1`: with annotations list, with SLASH_COMMAND annotation, without, empty list
- `extract_attachments/1`: with attachment list, without, malformed attachments
- `parse_timestamp/1`: valid ISO8601, invalid string, nil
- Content extraction priority: `argumentText` preferred over `text`

**Testability**: HIGH. `normalize/1` is a pure function (input map -> output struct). No external dependencies. Should be straightforward to test with various event shape fixtures.

### 3.4 HIGH — Notifications.Dedup (79 lines, 0 tests)

**File**: `lib/assistant/notifications/dedup.ex`

**Untested critical paths**:
- `init/0`: creates ETS table, idempotent on second call
- `duplicate?/2`: not seen -> false, recently seen -> true, seen but outside window -> false
- `record/2`: inserts entry, updates existing entry
- `sweep/0`: removes expired entries, preserves fresh entries, returns count
- `build_key/2`: SHA-256 hash consistency

**Testability**: HIGH. Pure ETS-based logic. No external dependencies. The `@dedup_window_ms` is hardcoded at 300,000ms which makes testing time-window boundaries harder — tests would need to manipulate time or the constant would need to be configurable for test.

**Note**: `build_key/2` uses SHA-256 of message content but the key is `{component, hash}` — this means different components with the same message are correctly treated as separate entries. Good design, but untested.

### 3.5 HIGH — Notifications.Router (233 lines, 0 tests)

**File**: `lib/assistant/notifications/router.ex`

**Untested critical paths**:
- `notify/4`: cast message dispatched correctly
- `handle_cast` dedup integration: duplicate suppressed, non-duplicate recorded + dispatched
- `match_rules/3`: severity threshold filtering, component filter matching, nil/empty component filter
- `dispatch/5`: matched rules -> dispatch to channels, no rules -> fallback
- `dispatch_fallback/2`: only :error/:critical dispatched, :info/:warning dropped, nil webhook config
- `dispatch_to_channel/2`: google_chat_webhook type handled, unknown type logged
- `format_message/4`: severity tag, timestamp, metadata formatting, empty metadata
- `handle_info(:sweep_dedup)`: triggers sweep, reschedules
- `load_rules/0`: DB query success, DB unavailable -> empty list (rescue)
- `String.to_existing_atom/1` on `rule.severity_min`: potential crash if atom doesn't exist

**Testability**: MODERATE. GenServer with DB dependency for rule loading and external HTTP for dispatch. The `match_rules/3` and `format_message/4` are private pure functions that could be tested through the public API with mocks. `load_rules/0` DB query can return `[]` in test (rescue path).

**Potential bug**: `String.to_existing_atom(rule.severity_min)` at line 153 will raise `ArgumentError` if the string doesn't match an existing atom. If a rule has `severity_min: "warn"` (instead of "warning"), the router will crash. This should use `String.to_atom/1` or a safe lookup map.

### 3.6 HIGH — Skills.Files.Search (173 lines, 0 tests)

**File**: `lib/assistant/skills/files/search.ex`

**Untested critical paths**:
- `execute/2`: extracts flags, builds query, calls Drive
- `build_query/3`: nil/nil/nil -> base query, query+type+folder -> compound query
- `resolve_type/1`: valid type -> MIME, unknown type -> error message
- `search_files/3`: empty results, populated results, Drive error
- `format_file_list/1` and `format_file_row/1`: file formatting
- `parse_limit/1`: nil -> default, string integer -> clamped, non-integer string -> default, integer -> clamped
- `escape_query/1`: single-quote escaping (SQL injection prevention for Drive query)
- `friendly_type/1`: known MIME types -> labels, unknown -> passthrough
- `format_size/1`: bytes, KB, MB formatting, string size parsing
- `format_time/1`: DateTime, string, nil

**Testability**: HIGH. The `execute/2` function accepts a `context.integrations.drive` override, making the Drive client injectable for testing. Many helpers are pure functions. `parse_limit`, `escape_query`, `format_size`, `format_time`, `friendly_type`, `build_query` are all testable in isolation if extracted or tested through `execute/2`.

### 3.7 HIGH — Skills.Files.Read (95 lines, 0 tests)

**File**: `lib/assistant/skills/files/read.ex`

**Untested critical paths**:
- `execute/2`: missing id -> error result, valid id -> read_and_format
- `read_and_format/3`: successful read, truncation at 8000 chars, :not_found error, generic error
- `build_header/2`: successful metadata fetch, failed metadata fetch -> empty header
- `maybe_truncate/1`: under limit -> no truncation, over limit -> truncated + note
- Google Workspace type detection (delegated to Drive.google_workspace_type?)

**Testability**: HIGH. Same injectable Drive client pattern as Search. Pure truncation logic.

### 3.8 HIGH — Skills.Files.Write (72 lines, 0 tests)

**File**: `lib/assistant/skills/files/write.ex`

**Untested critical paths**:
- `execute/2`: missing name -> error, nil content -> error, valid params -> create_file
- `create_file/5`: success with web_view_link, success without link, Drive error
- `maybe_add/3`: nil -> skip, empty string -> skip, value -> add to opts

**Testability**: HIGH. Injectable Drive client. Straightforward parameter validation + Drive mock responses.

### 3.9 MEDIUM — Google.Auth (90 lines, 0 tests)

**File**: `lib/assistant/integrations/google/auth.ex`

**Untested paths**:
- `token/0`: Goth.fetch success -> `{:ok, token_string}`, failure -> `{:error, reason}`
- `token!/0`: success -> token string, failure -> raises
- `configured?/0`: env set -> true, env nil -> false
- `scopes/0`: returns expected scope list

**Testability**: MODERATE. Depends on Goth GenServer. Can mock `Goth.fetch/1` or test `configured?` and `scopes` as pure functions.

### 3.10 MEDIUM — Google.Chat client (116 lines, 0 tests)

**File**: `lib/assistant/integrations/google/chat.ex`

**Untested paths**:
- `send_message/3`: success, API error (non-2xx), request failure, auth token failure
- `build_body/2`: without thread, with thread
- `build_query_params/1`: without thread, with thread
- `truncate_message/1`: under limit, over limit with truncation notice

**Testability**: MODERATE. Depends on Auth.token() and Req.post. `build_body`, `build_query_params`, `truncate_message` are pure but private. Test through `send_message` with mocked Auth and Req.

### 3.11 MEDIUM — Google.Drive client (299 lines, 0 tests)

**File**: `lib/assistant/integrations/google/drive.ex`

**Untested paths**:
- `list_files/2`, `get_file/1`, `read_file/2`, `create_file/3`: all require Google API mocking
- `type_to_mime/1`: pure function, easily testable
- `google_workspace_type?/1`: pure function
- `normalize_file/1`: pure function (private)

**Testability**: LOW-MODERATE. Heavy external dependency (GoogleApi.Drive.V3). `type_to_mime/1` and `google_workspace_type?/1` are public pure functions and easily testable.

### 3.12 MEDIUM — Notifications.GoogleChat webhook sender (61 lines, 0 tests)

**File**: `lib/assistant/notifications/google_chat.ex`

**Untested paths**:
- `send/3`: success (2xx), non-2xx response, request failure

**Testability**: LOW. Thin Req wrapper. Testable with HTTP mocking (bypass/mox).

### 3.13 MEDIUM — GoogleChatController (212 lines, 0 tests)

**File**: `lib/assistant_web/controllers/google_chat_controller.ex`

**Untested paths**:
- `event/2`: normalize success -> handle, normalize error -> 200 empty
- `handle_normalized/3` ADDED_TO_SPACE: welcome message JSON response
- `handle_normalized/3` MESSAGE: spawn async + "Processing..." response
- `derive_conversation_id/1`: with thread -> "gchat:space:thread", without -> "gchat:space"
- `build_reply_opts/1`: with thread -> thread_name option, without -> empty
- `process_and_reply/1`: orchestrator success -> Chat reply, orchestrator failure -> error message
- `ensure_engine_started/2`: already running, start success, already_started race, start failure

**Testability**: LOW. ConnCase-style controller test requires full Phoenix pipeline. The async processing spawns tasks that depend on Engine, ChatClient, and DynamicSupervisor. `derive_conversation_id/1` and `build_reply_opts/1` are private pure helpers that could be tested if extracted.

---

## 4. Testability Assessment

### Easily testable without external dependencies (pure functions):

| Module | Functions | LOC | Effort |
|--------|-----------|-----|--------|
| `Channels.GoogleChat` | `normalize/1` (all event types) | ~150 | Low |
| `Notifications.Dedup` | `init/0`, `duplicate?/2`, `record/2`, `sweep/0` | ~79 | Low |
| `Skills.Files.Search` | `execute/2` (via injectable drive mock) | ~173 | Low |
| `Skills.Files.Read` | `execute/2` (via injectable drive mock) | ~95 | Low |
| `Skills.Files.Write` | `execute/2` (via injectable drive mock) | ~72 | Low |
| `Google.Drive` | `type_to_mime/1`, `google_workspace_type?/1` | ~15 | Trivial |

### Testable with mocking/stubbing:

| Module | Requires | Effort |
|--------|----------|--------|
| `GoogleChatAuth` plug | JOSE test keys, mock Req for cert fetch | Medium |
| `Notifications.Router` | ETS (Dedup), mock dispatch channels | Medium |
| `Google.Chat` client | Mock Auth.token, mock Req.post | Medium |

### Requires infrastructure or integration setup:

| Module | Requires | Effort |
|--------|----------|--------|
| `GoogleChatController` | ConnCase, mock Engine/ChatClient | High |
| `Google.Drive` client | Mock GoogleApi.Drive.V3 modules | High |
| `Notifications.Router` (full) | DB for rule loading | High |

---

## 5. Recommendations

### Blocking (must fix before merge)

1. **Wire GoogleChatAuth plug into router** — The JWT verification plug exists but is NOT applied to the `/webhooks/google-chat` route. The endpoint is currently unauthenticated. This is a **security issue**.

   Either:
   - (a) Add `plug AssistantWeb.Plugs.GoogleChatAuth` to the webhook pipeline/scope, or
   - (b) Create a dedicated pipeline: `pipeline :google_chat_auth do plug GoogleChatAuth end`

2. **Fix `:telegex` compilation error** — The Telegram dependency breaks `mix compile`. Either:
   - (a) Add `:plug_router` as a dependency, or
   - (b) Remove `:telegex` if Telegram integration is not yet needed, or
   - (c) Make it an optional dependency

### Should add before merge (high-value, low-effort tests)

| Priority | Module | Test Type | Effort | Rationale |
|----------|--------|-----------|--------|-----------|
| P0 | `Channels.GoogleChat` normalize/1 | Unit (pure function) | Low | Core message normalization — every webhook goes through this |
| P0 | `Notifications.Dedup` | Unit (ETS-based) | Low | Dedup correctness prevents notification spam or missed alerts |
| P1 | `Skills.Files.Search` execute/2 | Unit (injectable mock) | Low | Drive query building + result formatting |
| P1 | `Skills.Files.Read` execute/2 | Unit (injectable mock) | Low | File read + truncation logic |
| P1 | `Skills.Files.Write` execute/2 | Unit (injectable mock) | Low | File creation + parameter validation |
| P1 | `Google.Drive` type_to_mime/1 | Unit (pure function) | Trivial | Maps user-friendly types to MIME |
| P1 | `GoogleChatAuth` validate_claims | Unit (through plug call/2) | Medium | JWT claim validation is security-critical |

### Tech debt (post-merge)

| Priority | Module | Notes |
|----------|--------|-------|
| P2 | `Notifications.Router` | GenServer test with mocked Dedup + dispatch. Test match_rules severity/component filtering |
| P2 | `GoogleChatController` | ConnCase integration test (ADDED_TO_SPACE response, MESSAGE ack) |
| P2 | `Google.Chat` client | Mocked HTTP test for send_message variants |
| P2 | `Google.Drive` client | Full mock test of list/get/read/create operations |
| P3 | `Google.Auth` | Thin Goth wrapper — low value-add from testing |
| P3 | `Notifications.GoogleChat` | Thin Req wrapper — low value-add from testing |

### Code quality observations

1. **`Router.match_rules` uses `String.to_existing_atom/1`** (line 153) which will crash if `rule.severity_min` is a string that isn't already an atom. Should use a safe lookup map instead.

2. **`Dedup.@dedup_window_ms` is hardcoded** — makes time-boundary testing difficult. Consider accepting it as a config option or at least allowing override in test.

3. **`GoogleChatController.derive_conversation_id/1` and `build_reply_opts/1`** are useful pure helpers buried as private functions. Extracting them (or testing through controller integration tests) would improve coverage.

4. **`Files.Search.escape_query/1`** only escapes single quotes. If the Drive API query syntax has other special characters that need escaping, this could be a latent injection point in the Drive search query.

---

## 6. Signal

```
Risk Tier: HIGH
Signal: RED
Coverage: 0% — no Phase 3 test files exist
Uncertainty Coverage: N/A (no HIGH areas explicitly flagged in coder handoff)
Findings:
  - SECURITY: GoogleChatAuth plug defined but NOT wired into router — webhook endpoint is unauthenticated
  - BUILD: :telegex dependency compilation failure blocks mix test entirely
  - COVERAGE: 0 test files for 15 new source files (~1,739 LOC)
  - BUG: Router.match_rules uses String.to_existing_atom/1 which will crash on unknown severity strings
  - Several modules (normalize/1, Dedup, file skill handlers) are highly testable pure functions — easy wins
```

**RED rationale**: Two issues drive the RED signal:

1. **Security**: The GoogleChatAuth plug is not wired into the router. The Google Chat webhook endpoint has zero authentication, which is a functional security gap. The plug code exists and looks correct, but it's inert.

2. **Zero test coverage**: 15 new files totaling ~1,739 lines with no test files at all. While some modules are thin wrappers (Auth, Notifications.GoogleChat), others contain critical business logic (normalize/1, Dedup, file skill handlers with parameter validation) and security logic (JWT verification) that should have basic test coverage before merge.

The compilation blocker (telegex) additionally prevents verifying that existing tests still pass.
