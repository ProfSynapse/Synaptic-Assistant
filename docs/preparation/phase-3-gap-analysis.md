# Phase 3 Gap Analysis: First Channel + Integrations

> Produced by PACT Preparer on 2026-02-18
> Phase 3 scope from `docs/plans/skills-first-assistant-plan.md` lines 644-649

## Executive Summary

Phase 3 adds the first external channel (Google Chat), the first integration client (Google Drive), basic file skills, and a notification/alerting system. The existing codebase from Phases 1 and 2 provides a solid foundation: the orchestrator engine, skill system, memory system, and schemas are all in place. However, the entire channel adapter layer, integration client layer (beyond OpenRouter), and notification system are absent.

**Key findings:**
- No `lib/assistant/channels/` directory exists. The `WebhookController` has placeholder stubs for Google Chat and Telegram endpoints.
- `lib/assistant/integrations/` contains only `openrouter.ex`. No Google auth, Drive, or Chat client modules exist.
- `lib/assistant/notifications/` does not exist. Schemas for `notification_channels` and `notification_rules` are defined but have no runtime logic.
- No `lib/assistant/skills/files/` directory exists. No file domain skills.
- Dependencies `goth`, `req`, and `google_api_drive` are **already in mix.exs** (ready to use).
- A new dependency `joken` (JWT verification) is needed for Google Chat webhook authentication.
- The `Conversation` schema already has a `channel` string field, so channel-aware conversations are supported at the data layer.

---

## Table of Contents

1. [Codebase Inventory: What Exists](#1-codebase-inventory-what-exists)
2. [Google Chat Channel Adapter](#2-google-chat-channel-adapter)
3. [Google Drive Integration Client](#3-google-drive-integration-client)
4. [File Domain Skills](#4-file-domain-skills)
5. [Notification System](#5-notification-system)
6. [New Dependencies](#6-new-dependencies)
7. [New Files and Modules Required](#7-new-files-and-modules-required)
8. [Coding Wave Order](#8-coding-wave-order)
9. [Security Considerations](#9-security-considerations)
10. [References](#10-references)

---

## 1. Codebase Inventory: What Exists

### Already Built (Phases 1 & 2)

| Component | Location | Status |
|-----------|----------|--------|
| Orchestrator Engine | `lib/assistant/orchestrator/engine.ex` | Complete GenServer, multi-agent + single-loop modes |
| Skill System | `lib/assistant/skills/` | Handler behaviour, Registry, Executor, Loader, Watcher |
| Memory System | `lib/assistant/memory/` | Store, Search, ContextBuilder, Compaction, Agent, ContextMonitor, TurnClassifier |
| Memory Skills | `lib/assistant/skills/memory/` | save, search, get, extract_entities, query_entity_graph, close_relation, compact_conversation |
| Task Skills | `lib/assistant/skills/tasks/` | create, search, get, update, delete |
| Workflow Builder | `lib/assistant/skills/workflow/build.ex` | Meta-skill for composing workflows |
| OpenRouter Client | `lib/assistant/integrations/openrouter.ex` | LLM + streaming + tool-calling |
| Circuit Breakers | `lib/assistant/resilience/circuit_breaker.ex` | Four-level hierarchy |
| Rate Limiter | `lib/assistant/resilience/rate_limiter.ex` | |
| CLI Parser/Extractor | `lib/assistant/orchestrator/cli_parser.ex`, `cli_extractor.ex` | |
| Sentinel | `lib/assistant/orchestrator/sentinel.ex` | Security gate for irreversible actions |
| Schemas | `lib/assistant/schemas/` | All core schemas including notification_channel, notification_rule |
| Web Endpoint | `lib/assistant_web/` | Router, HealthController, placeholder WebhookController |
| Supervision Tree | `lib/assistant/application.ex` | Full OTP tree with DynamicSupervisor for conversations |
| Config System | `lib/assistant/config/loader.ex`, `prompt_loader.ex` | YAML-based config + prompt templates |
| Scheduler | `lib/assistant/scheduler.ex`, `workers/compaction_worker.ex` | Oban-based |

### Key Interfaces to Wire Into

1. **SkillContext** (`lib/assistant/skills/context.ex`): Has `:channel` atom field and `:integrations` map (supports `:drive`, `:gmail`, `:calendar`, `:hubspot` keys). File skills will receive the Drive client through `context.integrations.drive`.

2. **Handler behaviour** (`lib/assistant/skills/handler.ex`): `execute(flags, context) :: {:ok, Result.t()} | {:error, term()}`. File skills implement this.

3. **Orchestrator Engine** (`lib/assistant/orchestrator/engine.ex`): Needs a `handle_incoming_message/3` or similar entry point that the channel adapter calls. Currently the Engine is started via `start_conversation/2` under the ConversationSupervisor. The channel adapter will look up or start a conversation engine and call into it.

4. **WebhookController** (`lib/assistant_web/controllers/webhook_controller.ex`): Placeholder `google_chat/2` action returns `%{status: "ok"}`. Needs full implementation.

5. **Router** (`lib/assistant_web/router.ex`): Already has `post "/webhooks/google-chat"` route.

6. **Notification Schemas**: `NotificationChannel` and `NotificationRule` schemas exist with proper fields but have zero runtime logic.

### What Does NOT Exist

| Component | Planned Location | Status |
|-----------|-----------------|--------|
| Channel adapter behaviour | `lib/assistant/channels/adapter.ex` | Missing |
| Google Chat adapter | `lib/assistant/channels/google_chat.ex` | Missing |
| ConversationMessage struct | `lib/assistant/channels/message.ex` | Missing |
| Google auth client (Goth wrapper) | `lib/assistant/integrations/google/auth.ex` | Missing |
| Google Drive client | `lib/assistant/integrations/google/drive.ex` | Missing |
| Google Chat API client | `lib/assistant/integrations/google/chat.ex` | Missing |
| File skills (read/write/search) | `lib/assistant/skills/files/` | Missing |
| Notification router | `lib/assistant/notifications/router.ex` | Missing |
| Notification Google Chat sender | `lib/assistant/notifications/google_chat.ex` | Missing |
| JWT verification plug | `lib/assistant_web/plugs/google_chat_auth.ex` | Missing |
| Webhook controller (real impl) | `lib/assistant_web/controllers/google_chat_controller.ex` | Placeholder only |

---

## 2. Google Chat Channel Adapter

### 2.1 How Google Chat App Webhooks Work

Google Chat apps configured with an HTTP endpoint receive POST requests from Google whenever a user interacts with the app. The app is registered in the Google Cloud Console with a URL pointing to your server (e.g., `https://your-app.railway.app/webhooks/google-chat`).

**Event types delivered to your endpoint:**

| eventType | Trigger |
|-----------|---------|
| `MESSAGE` | User sends a message, @mentions the app, or uses a slash command |
| `ADDED_TO_SPACE` | User adds the app to a space or DM |
| `REMOVED_FROM_SPACE` | User removes the app from a space |
| `CARD_CLICKED` | User clicks a button on a card message |
| `WIDGET_UPDATED` | User interacts with an updatable widget |
| `APP_COMMAND` | User invokes a slash command or quick command |
| `APP_HOME` | User opens the app's home screen in a DM |
| `SUBMIT_FORM` | User submits a form from the app home |

**Incoming event payload structure** (MESSAGE event):

```json
{
  "type": "MESSAGE",
  "eventTime": "2026-02-18T10:30:00.000000Z",
  "space": {
    "name": "spaces/AAAA_BBBB",
    "displayName": "My Space",
    "type": "ROOM",
    "singleUserBotDm": false
  },
  "message": {
    "name": "spaces/AAAA_BBBB/messages/1234567890",
    "sender": {
      "name": "users/123456789",
      "displayName": "Jane Doe",
      "avatarUrl": "https://lh3.googleusercontent.com/...",
      "email": "jane@example.com",
      "type": "HUMAN"
    },
    "createTime": "2026-02-18T10:30:00.000000Z",
    "text": "@AssistantBot search my drive for Q1 report",
    "argumentText": " search my drive for Q1 report",
    "thread": {
      "name": "spaces/AAAA_BBBB/threads/CCCC_DDDD"
    },
    "annotations": [
      {
        "type": "USER_MENTION",
        "startIndex": 0,
        "length": 14,
        "userMention": {
          "user": { "name": "users/app_bot_id", "type": "BOT" },
          "type": "MENTION"
        }
      }
    ]
  },
  "user": {
    "name": "users/123456789",
    "displayName": "Jane Doe",
    "avatarUrl": "https://lh3.googleusercontent.com/...",
    "email": "jane@example.com",
    "type": "HUMAN"
  },
  "common": {
    "hostApp": "CHAT"
  }
}
```

**Slash command payload** (APP_COMMAND event):

```json
{
  "type": "APP_COMMAND",
  "eventTime": "2026-02-18T10:30:00.000000Z",
  "space": { "name": "spaces/AAAA_BBBB", "type": "DM" },
  "message": {
    "name": "spaces/AAAA_BBBB/messages/5678",
    "sender": { "name": "users/123456789", "email": "jane@example.com", "type": "HUMAN" },
    "text": "/search Q1 report",
    "argumentText": "Q1 report",
    "slashCommand": { "commandId": "1" },
    "annotations": [
      {
        "type": "SLASH_COMMAND",
        "slashCommand": { "bot": { "name": "users/bot_id" }, "commandId": "1", "commandName": "/search", "triggersDialog": false }
      }
    ]
  },
  "user": { "name": "users/123456789", "email": "jane@example.com", "type": "HUMAN" }
}
```

### 2.2 JWT Verification (SECURITY-CRITICAL)

Every request from Google Chat includes an `Authorization: Bearer <token>` header. The token is a JWT signed by Google.

**Verification parameters (when Authentication Audience = Project Number):**

| Field | Value |
|-------|-------|
| Issuer (`iss`) | `chat@system.gserviceaccount.com` |
| Audience (`aud`) | Your Google Cloud project number (e.g., `1234567890`) |
| Certificate URL | `https://www.googleapis.com/service_accounts/v1/metadata/x509/chat@system.gserviceaccount.com` |
| Algorithm | RS256 |
| Token location | `Authorization: Bearer <JWT>` header |

**Verification steps (implement as a Phoenix Plug):**

1. Extract the Bearer token from the `Authorization` header
2. Fetch Google's public X.509 certificates from the certificate URL (cache them with a TTL of ~1 hour)
3. Decode the JWT header to get the `kid` (key ID) claim
4. Look up the matching certificate by `kid`
5. Convert the X.509 certificate to a public key
6. Verify the JWT signature using the public key (RS256)
7. Verify `iss` == `chat@system.gserviceaccount.com`
8. Verify `aud` == configured project number
9. Verify `exp` > current time (not expired)
10. If any check fails, return HTTP 401

**Elixir implementation approach:**

Use `joken` (v2.6+) with `joken_jwks` or manual key fetching:

```elixir
# In lib/assistant_web/plugs/google_chat_auth.ex
defmodule AssistantWeb.Plugs.GoogleChatAuth do
  import Plug.Conn
  require Logger

  @google_certs_url "https://www.googleapis.com/service_accounts/v1/metadata/x509/chat@system.gserviceaccount.com"
  @expected_issuer "chat@system.gserviceaccount.com"

  def init(opts), do: opts

  def call(conn, _opts) do
    with {:ok, token} <- extract_bearer_token(conn),
         {:ok, claims} <- verify_jwt(token) do
      assign(conn, :google_chat_claims, claims)
    else
      {:error, reason} ->
        Logger.warning("Google Chat JWT verification failed: #{inspect(reason)}")
        conn |> send_resp(401, "Unauthorized") |> halt()
    end
  end

  defp extract_bearer_token(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] -> {:ok, token}
      _ -> {:error, :missing_bearer_token}
    end
  end

  defp verify_jwt(token) do
    project_number = Application.fetch_env!(:assistant, :google_cloud_project_number)
    # 1. Fetch cached certs
    # 2. Decode JWT header to get kid
    # 3. Find matching cert, convert to public key
    # 4. Verify signature (RS256), iss, aud, exp
    # Use Joken + JOSE for this
  end
end
```

**Certificate caching strategy:**

Use an ETS table or a simple Agent/GenServer to cache fetched certificates. Google rotates certificates roughly daily, so a 1-hour TTL with lazy refresh on cache miss is appropriate. The certificates are fetched as a JSON map `{kid => PEM_cert_string}`.

### 2.3 The 30-Second Timeout and Async Reply Pattern

Google Chat requires a synchronous HTTP response **within 30 seconds**. For LLM-based processing that may take longer:

**Recommended pattern:**

1. **Immediate acknowledgment**: Return a synchronous response within 30 seconds. For simple queries that the orchestrator handles quickly, return the actual response. For complex queries, return a "thinking..." message.

2. **Async processing**: Spawn the orchestrator conversation asynchronously (it runs as a GenServer anyway). When the orchestrator completes, use the Google Chat REST API to send the reply.

3. **Async reply via REST API**: POST to `https://chat.googleapis.com/v1/{space}/messages` using service account auth.

```
Webhook POST arrives
  |
  v
Phoenix Controller receives event
  |
  v
Start/lookup Orchestrator Engine (async)
  |
  +---> Return sync response: {"text": "Processing..."} (within 30s)
  |
  v (async)
Orchestrator processes message, generates response
  |
  v
Google Chat REST API: POST spaces/{space}/messages with response text
```

### 2.4 Sending Messages via Google Chat REST API

**Endpoint:** `POST https://chat.googleapis.com/v1/{parent=spaces/*}/messages`

**Authentication:** Service account with scope `https://www.googleapis.com/auth/chat.bot`

**Request body:**

```json
{
  "text": "Here are the results of your search...",
  "thread": {
    "name": "spaces/AAAA_BBBB/threads/CCCC_DDDD"
  }
}
```

**Query parameters:**
- `messageReplyOption`: Set to `REPLY_MESSAGE_FALLBACK_TO_NEW_THREAD` to reply in thread

**Max message size:** 32,000 bytes

**Implementation in Elixir (using Req + Goth):**

```elixir
defmodule Assistant.Integrations.Google.Chat do
  @base_url "https://chat.googleapis.com/v1"
  @scope "https://www.googleapis.com/auth/chat.bot"

  def send_message(space_name, text, opts \\ []) do
    token = get_access_token()
    thread_name = Keyword.get(opts, :thread_name)

    body = %{"text" => text}
    body = if thread_name, do: Map.put(body, "thread", %{"name" => thread_name}), else: body

    query_params = if thread_name,
      do: [messageReplyOption: "REPLY_MESSAGE_FALLBACK_TO_NEW_THREAD"],
      else: []

    Req.post("#{@base_url}/#{space_name}/messages",
      json: body,
      params: query_params,
      headers: [{"authorization", "Bearer #{token}"}]
    )
  end

  defp get_access_token do
    {:ok, %{token: token}} = Goth.fetch(Assistant.Goth)
    token
  end
end
```

### 2.5 ChannelAdapter Behaviour

Define a behaviour that all channel adapters implement:

```elixir
defmodule Assistant.Channels.Adapter do
  @type normalized_message :: Assistant.Channels.Message.t()

  @callback normalize(raw_event :: map()) :: {:ok, normalized_message()} | {:error, term()}
  @callback send_reply(space_id :: String.t(), text :: String.t(), opts :: keyword()) :: :ok | {:error, term()}
  @callback name() :: atom()
end
```

### 2.6 ConversationMessage Struct

Already specified in the plan (lines 289-300). Maps to the `channel` and `content` fields in the existing `Message` schema.

```elixir
defmodule Assistant.Channels.Message do
  @type t :: %__MODULE__{
    id: String.t(),
    channel: atom(),
    channel_message_id: String.t(),
    space_id: String.t(),
    thread_id: String.t() | nil,
    user_id: String.t(),
    user_display_name: String.t() | nil,
    user_email: String.t() | nil,
    content: String.t(),
    argument_text: String.t() | nil,
    slash_command: String.t() | nil,
    attachments: [map()],
    metadata: map(),
    timestamp: DateTime.t()
  }

  defstruct [:id, :channel, :channel_message_id, :space_id, :thread_id,
             :user_id, :user_display_name, :user_email, :content,
             :argument_text, :slash_command, attachments: [], metadata: %{},
             timestamp: nil]
end
```

---

## 3. Google Drive Integration Client

### 3.1 Authentication: Goth Setup

`goth` v1.4.5 is already in `mix.exs`. It needs to be wired into the supervision tree.

**Supervision tree addition** (in `application.ex`):

```elixir
# Add before Oban in the children list
{Goth, name: Assistant.Goth, source: {:service_account, credentials, scopes: scopes}}
```

Where `credentials` is loaded from the `GOOGLE_APPLICATION_CREDENTIALS` env var (already read in `runtime.exs`) and `scopes` covers all needed Google APIs:

```elixir
@google_scopes [
  "https://www.googleapis.com/auth/chat.bot",
  "https://www.googleapis.com/auth/drive.readonly",
  "https://www.googleapis.com/auth/drive.file"
]
```

**Token usage with google_api_drive:**

```elixir
{:ok, %{token: access_token}} = Goth.fetch(Assistant.Goth)
conn = GoogleApi.Drive.V3.Connection.new(access_token)
{:ok, file_list} = GoogleApi.Drive.V3.Api.Files.drive_files_list(conn, q: "name contains 'report'")
```

### 3.2 Google Drive API: Key Operations

**Base URL:** `https://www.googleapis.com/drive/v3`

**Required scopes:**
- `https://www.googleapis.com/auth/drive.readonly` (list + read)
- `https://www.googleapis.com/auth/drive.file` (files created/opened by app)
- `https://www.googleapis.com/auth/drive` (full access, if needed for write)

#### 3.2.1 List Files

**Elixir function:** `GoogleApi.Drive.V3.Api.Files.drive_files_list(conn, opts)`

**Key parameters:**
- `q` -- Search query (see syntax below)
- `pageSize` -- Max results per page (default 100, max 1000)
- `pageToken` -- Pagination token
- `orderBy` -- Sort (e.g., `modifiedTime desc`, `name`)
- `fields` -- Response fields to include (e.g., `files(id,name,mimeType,modifiedTime)`)
- `supportsAllDrives` -- Boolean, true for shared drives
- `includeItemsFromAllDrives` -- Boolean
- `corpora` -- `user`, `domain`, `drive`, `allDrives`
- `driveId` -- Specific shared drive ID

**Search query syntax (`q` parameter):**

| Query | Example |
|-------|---------|
| By name | `name = 'Q1 Report'` or `name contains 'report'` |
| By MIME type | `mimeType = 'application/vnd.google-apps.document'` |
| By folder | `'FOLDER_ID' in parents` |
| By modified time | `modifiedTime > '2026-01-01T00:00:00'` |
| Full text | `fullText contains 'quarterly review'` |
| Exclude trash | `trashed = false` |
| Combined | `mimeType = 'application/vnd.google-apps.document' and name contains 'report' and trashed = false` |

**Response:** `FileList` with `files[]` array and `nextPageToken`.

#### 3.2.2 Get File Metadata

**Elixir function:** `GoogleApi.Drive.V3.Api.Files.drive_files_get(conn, file_id, opts)`

Returns a `File` object with `id`, `name`, `mimeType`, `modifiedTime`, `size`, `parents`, etc.

#### 3.2.3 Export Google Workspace Documents

**Elixir function:** `GoogleApi.Drive.V3.Api.Files.drive_files_export(conn, file_id, mime_type, opts)`

Google Workspace documents (Docs, Sheets, Slides) cannot be downloaded directly. They must be **exported** to a standard format.

**MIME type mapping for Google Workspace files:**

| Google Type | Google MIME Type | Export To | Export MIME Type |
|-------------|-----------------|-----------|-----------------|
| Google Docs | `application/vnd.google-apps.document` | Plain text | `text/plain` |
| | | PDF | `application/pdf` |
| | | DOCX | `application/vnd.openxmlformats-officedocument.wordprocessingml.document` |
| | | HTML | `text/html` |
| Google Sheets | `application/vnd.google-apps.spreadsheet` | CSV | `text/csv` |
| | | XLSX | `application/vnd.openxmlformats-officedocument.spreadsheetml.sheet` |
| | | PDF | `application/pdf` |
| Google Slides | `application/vnd.google-apps.presentation` | PDF | `application/pdf` |
| | | PPTX | `application/vnd.openxmlformats-officedocument.presentationml.presentation` |
| Google Drawings | `application/vnd.google-apps.drawing` | PNG | `image/png` |
| | | SVG | `image/svg+xml` |
| | | PDF | `application/pdf` |

**Export limit:** 10 MB maximum exported content size.

**Important distinction:** Regular files (PDFs, images, etc.) use `drive_files_get` with `alt: "media"` to download. Google Workspace files use `drive_files_export` to convert and download.

### 3.3 Drive Client Wrapper Module

```elixir
defmodule Assistant.Integrations.Google.Drive do
  @moduledoc "Thin wrapper around GoogleApi.Drive.V3 with Goth auth."

  @doc "List files matching a query."
  def list_files(query, opts \\ [])
  # -> {:ok, [%{id, name, mimeType, modifiedTime}]} | {:error, term()}

  @doc "Get file metadata."
  def get_file(file_id)
  # -> {:ok, %{id, name, mimeType, size, ...}} | {:error, term()}

  @doc "Read file content. Auto-detects Google Workspace files and exports."
  def read_file(file_id, opts \\ [])
  # -> {:ok, binary()} | {:error, term()}
  # opts: [export_mime_type: "text/plain"] for Workspace files

  @doc "Check if a MIME type is a Google Workspace type requiring export."
  def google_workspace_type?(mime_type)
  # -> boolean
end
```

### 3.4 Goth Configuration in runtime.exs

The existing `runtime.exs` reads `GOOGLE_APPLICATION_CREDENTIALS` but stores it as a raw string. It needs to be parsed as JSON for Goth:

```elixir
# In runtime.exs — update the existing google_creds block:
if google_creds = System.get_env("GOOGLE_APPLICATION_CREDENTIALS") do
  # Goth expects decoded JSON map, not a file path
  credentials =
    if String.starts_with?(google_creds, "{") do
      Jason.decode!(google_creds)
    else
      google_creds |> File.read!() |> Jason.decode!()
    end

  config :assistant, :google_credentials, credentials
end
```

---

## 4. File Domain Skills

### 4.1 Skills to Implement

Per the plan, Phase 3 includes basic file skills: `files.read`, `files.write`, `files.search`.

| Skill | Action | Implementation |
|-------|--------|---------------|
| `files.search` | Search Drive files | `drive_files_list` with `q` parameter |
| `files.read` | Read file content | `drive_files_get` (binary) or `drive_files_export` (Workspace) |
| `files.write` | Create/update file | `drive_files_create` / `drive_files_update` |

**Note:** `files.move` and `files.sync` are deferred to Phase 4.

### 4.2 Skill File Structure

Each skill needs both a markdown definition file (in `priv/skills/files/`) and an Elixir handler module (in `lib/assistant/skills/files/`).

**Example: `files.search` handler skeleton:**

```elixir
defmodule Assistant.Skills.Files.Search do
  @behaviour Assistant.Skills.Handler

  @impl true
  def execute(flags, context) do
    query = Map.get(flags, "query", "")
    mime_type = Map.get(flags, "type")  # optional: doc, sheet, pdf, etc.
    folder = Map.get(flags, "folder")   # optional: folder ID or name
    limit = Map.get(flags, "limit", "20") |> String.to_integer()

    drive = context.integrations.drive

    q_parts = build_query_parts(query, mime_type, folder)
    case drive.list_files(Enum.join(q_parts, " and "), pageSize: limit) do
      {:ok, files} ->
        content = format_file_list(files)
        {:ok, %Assistant.Skills.Result{status: :ok, content: content}}
      {:error, reason} ->
        {:error, reason}
    end
  end
end
```

### 4.3 Skill Markdown Definitions

Place in `priv/skills/files/` directory:

- `SKILL.md` -- Domain index
- `search.md` -- files.search skill definition
- `read.md` -- files.read skill definition
- `write.md` -- files.write skill definition

---

## 5. Notification System

### 5.1 Architecture

The notification system routes errors and alerts to configured channels (Google Chat webhook, email, etc.) with deduplication and throttling.

**Components:**

| Module | Purpose |
|--------|---------|
| `Assistant.Notifications.Router` | GenServer that receives alert events, applies rules, deduplicates, and dispatches |
| `Assistant.Notifications.GoogleChat` | Sends messages to a Google Chat space via incoming webhook URL |
| `Assistant.Notifications.Dedup` | ETS-based dedup tracker with sliding window |

### 5.2 Router Design

The Router GenServer:

1. **Receives** alert events via `Router.notify/2` (severity, component, message)
2. **Queries** notification rules from DB (or cached in ETS) to find matching channels
3. **Deduplicates** using a composite key of `{component, message_hash}` with a configurable window (default: 5 minutes)
4. **Dispatches** to the appropriate sender module (`GoogleChat`, `Email`)
5. **Throttles** using a sliding window rate limiter (max N alerts per channel per window)

```elixir
defmodule Assistant.Notifications.Router do
  use GenServer

  @type severity :: :info | :warning | :error | :critical
  @type alert :: %{
    severity: severity(),
    component: String.t(),
    message: String.t(),
    metadata: map()
  }

  def notify(severity, component, message, metadata \\ %{})
  # -> :ok | {:error, :throttled} | {:error, :dedup}
end
```

### 5.3 Google Chat Incoming Webhook (for Notifications)

This is separate from the Chat App bot. An incoming webhook is a simple URL that accepts POST requests with a JSON body.

**Webhook URL format:** `https://chat.googleapis.com/v1/spaces/SPACE_ID/messages?key=KEY&token=TOKEN`

The URL is stored in the `notification_channels` table (in the `config` field) and configured via `GOOGLE_CHAT_WEBHOOK_URL` env var (already in `runtime.exs`).

**Sending a notification:**

```elixir
defmodule Assistant.Notifications.GoogleChat do
  def send(webhook_url, message) do
    body = %{
      "text" => message,
      "cardsV2" => [format_alert_card(message)]  # optional: rich card
    }

    Req.post(webhook_url, json: body)
  end
end
```

### 5.4 Dedup Strategy

Use ETS with a sliding window:

```elixir
# Key: {component, hash(message)}
# Value: timestamp of first occurrence
# Window: 5 minutes (configurable)
# If key exists and timestamp is within window -> skip (dedup)
# If key exists and timestamp is outside window -> update timestamp, dispatch
# If key doesn't exist -> insert, dispatch
```

Cleanup: periodic sweep of expired entries (Oban cron or Process.send_after).

---

## 6. New Dependencies

### Required

| Package | Version | Purpose | Notes |
|---------|---------|---------|-------|
| `joken` | `~> 2.6` | JWT creation/verification | For Google Chat webhook JWT verification |
| `joken_jwks` | `~> 1.6` | JWKS key fetching | Optional -- could also use manual cert fetching with JOSE (bundled with joken) |

### Already Present (no changes needed)

| Package | In mix.exs | Purpose |
|---------|-----------|---------|
| `goth` | `~> 1.4` | Google OAuth2 service account auth |
| `req` | `~> 0.5` | HTTP client for REST API calls |
| `google_api_drive` | `~> 0.32` | Google Drive API Elixir client |
| `jason` | `~> 1.4` | JSON encoding |
| `oban` | `~> 2.18` | Job queue (for async notification dispatch) |
| `fuse` | `~> 2.5` | Circuit breaker |

### Alternative: Skip joken, use JOSE directly

Since `goth` already depends on `jose` (JOSE is a transitive dependency), you could implement JWT verification using JOSE directly without adding `joken`. This avoids a new dependency:

```elixir
# Verify using JOSE directly (already available via goth's deps):
{true, %{fields: claims}, _jws} = JOSE.JWT.verify(jwk, token)
```

**Recommendation:** Use JOSE directly (already a transitive dependency) rather than adding `joken`. This keeps the dependency tree leaner. Implement a simple verification module that fetches certs, caches them, and verifies with JOSE.

---

## 7. New Files and Modules Required

### Wave 1: Google Auth + Channel Infrastructure

| File | Module | Purpose |
|------|--------|---------|
| `lib/assistant/integrations/google/auth.ex` | `Assistant.Integrations.Google.Auth` | Goth wrapper, token fetching, scope management |
| `lib/assistant/channels/adapter.ex` | `Assistant.Channels.Adapter` | ChannelAdapter behaviour |
| `lib/assistant/channels/message.ex` | `Assistant.Channels.Message` | Normalized ConversationMessage struct |
| `lib/assistant_web/plugs/google_chat_auth.ex` | `AssistantWeb.Plugs.GoogleChatAuth` | JWT verification plug |

### Wave 2: Google Chat Adapter + Controller

| File | Module | Purpose |
|------|--------|---------|
| `lib/assistant/channels/google_chat.ex` | `Assistant.Channels.GoogleChat` | Google Chat channel adapter (implements Adapter behaviour) |
| `lib/assistant/integrations/google/chat.ex` | `Assistant.Integrations.Google.Chat` | Google Chat REST API client (send messages) |
| `lib/assistant_web/controllers/google_chat_controller.ex` | `AssistantWeb.GoogleChatController` | Full webhook controller (replaces placeholder) |

### Wave 3: Google Drive Client + File Skills

| File | Module | Purpose |
|------|--------|---------|
| `lib/assistant/integrations/google/drive.ex` | `Assistant.Integrations.Google.Drive` | Drive API wrapper (list, get, export, create) |
| `lib/assistant/skills/files/search.ex` | `Assistant.Skills.Files.Search` | files.search handler |
| `lib/assistant/skills/files/read.ex` | `Assistant.Skills.Files.Read` | files.read handler |
| `lib/assistant/skills/files/write.ex` | `Assistant.Skills.Files.Write` | files.write handler |
| `priv/skills/files/SKILL.md` | -- | files domain index |
| `priv/skills/files/search.md` | -- | files.search skill definition |
| `priv/skills/files/read.md` | -- | files.read skill definition |
| `priv/skills/files/write.md` | -- | files.write skill definition |

### Wave 4: Notification System

| File | Module | Purpose |
|------|--------|---------|
| `lib/assistant/notifications/router.ex` | `Assistant.Notifications.Router` | Alert router GenServer with rule matching and dedup |
| `lib/assistant/notifications/google_chat.ex` | `Assistant.Notifications.GoogleChat` | Google Chat incoming webhook sender |
| `lib/assistant/notifications/dedup.ex` | `Assistant.Notifications.Dedup` | ETS-based dedup with sliding window |

### Modifications to Existing Files

| File | Change |
|------|--------|
| `lib/assistant/application.ex` | Add Goth, Notifications.Router to supervision tree |
| `lib/assistant_web/router.ex` | Update google-chat route to use new controller + auth plug |
| `config/runtime.exs` | Parse Google credentials JSON, add `google_cloud_project_number` config |
| `config/config.yaml` | Add `google_chat` and `notifications` sections |
| `lib/assistant/skills/context.ex` | No changes needed (`:drive` key already in integrations type) |

---

## 8. Coding Wave Order

Dependencies flow left-to-right. Each wave can begin only after the previous wave is stable.

```
Wave 1: Infrastructure           Wave 2: Channel            Wave 3: Drive + Skills        Wave 4: Notifications
+------------------------+       +--------------------+     +-------------------------+    +--------------------+
| Google.Auth (Goth)     |------>| Google.Chat client |     | Google.Drive client     |    | Notifications.Router|
| Channels.Adapter       |------>| GoogleChat adapter  |     | Files.Search handler   |    | Notifications.GChat |
| Channels.Message       |------>| GoogleChatAuth plug |     | Files.Read handler     |    | Notifications.Dedup |
| application.ex (Goth)  |       | GoogleChatController|     | Files.Write handler    |    | application.ex      |
| runtime.exs updates    |       | router.ex update    |     | Skill markdown files   |    | config.yaml update  |
+------------------------+       +--------------------+     +-------------------------+    +--------------------+
```

**Wave 1 - Foundation (no external API calls needed)**
- Define the ChannelAdapter behaviour and ConversationMessage struct
- Create the Google Auth module (Goth wrapper with scope management)
- Add Goth to the supervision tree in application.ex
- Update runtime.exs to properly parse Google credentials JSON
- Add `google_cloud_project_number` to runtime config

**Wave 2 - Google Chat Channel (requires Goth from Wave 1)**
- Implement JWT verification plug (GoogleChatAuth)
- Implement Google Chat REST API client (send_message)
- Implement GoogleChat channel adapter (normalize events, send replies)
- Create the full GoogleChatController (handle events, dispatch to orchestrator)
- Update router.ex to use new controller and auth plug
- Wire the adapter to the Orchestrator Engine (lookup/start conversation, send user message)

**Wave 3 - Drive + File Skills (requires Goth from Wave 1, independent of Wave 2)**
- Implement Google Drive client wrapper
- Implement files.search, files.read, files.write handlers
- Create skill markdown definitions
- Register file skills in the registry

**Wave 4 - Notifications (independent of Waves 2-3)**
- Implement Notifications.Router GenServer
- Implement GoogleChat notification sender (incoming webhook)
- Implement ETS-based dedup
- Add Router to supervision tree
- Wire circuit breaker and orchestrator errors to the notification router

**Waves 3 and 4 can run in parallel** since they have no shared files. Wave 2 must complete before the system is fully functional (end-to-end message flow), but Wave 3 can start as soon as Wave 1 is done.

---

## 9. Security Considerations

### JWT Verification

- **Never skip JWT verification** on the Google Chat webhook endpoint. All incoming requests must be authenticated.
- Cache Google's public certificates (rotate hourly). Do not fetch certs on every request.
- Use the `kid` header claim to select the correct certificate. Google rotates keys.
- Verify `iss`, `aud`, and `exp` claims explicitly.
- Return HTTP 401 for any verification failure. Do not leak error details in the response.

### Service Account Credentials

- The `GOOGLE_APPLICATION_CREDENTIALS` env var contains the service account private key. This is the most sensitive credential in the system.
- Never log the credentials JSON. The existing Cloak.Ecto setup should be used for any stored credentials.
- Use domain-wide delegation scopes conservatively. Only request the scopes you need.

### Notification Webhook URL

- The `GOOGLE_CHAT_WEBHOOK_URL` contains an auth token. Treat it as a secret.
- Store it in env vars only, never in code or config files.

### File Access

- The service account only has access to files explicitly shared with it, or files in the service account's own Drive.
- For domain-wide delegation, ensure the admin has granted only the required scopes.
- Validate file IDs before passing to the Drive API to prevent path traversal or injection.

---

## 10. References

### Official Google Documentation

- [Receive and respond to Google Chat interaction events](https://developers.google.com/workspace/chat/receive-respond-interactions)
- [Verify requests from Google Chat](https://developers.google.com/workspace/chat/verify-requests-from-chat)
- [Google Chat API: spaces.messages.create](https://developers.google.com/workspace/chat/api/reference/rest/v1/spaces.messages/create)
- [Send a message using the Google Chat API](https://developers.google.com/workspace/chat/create-messages)
- [Authenticate as a Google Chat app (service accounts)](https://developers.google.com/chat/api/guides/auth/service-accounts)
- [Google Workspace MIME types](https://developers.google.com/workspace/drive/api/guides/mime-types)
- [Drive API: files.export](https://developers.google.com/workspace/drive/api/reference/rest/v3/files/export)
- [Drive API: files.list](https://developers.google.com/workspace/drive/api/reference/rest/v3/files/list)
- [Drive API: search query syntax](https://developers.google.com/workspace/drive/api/guides/search-files)
- [Google Chat EventType reference](https://developers.google.com/workspace/chat/api/reference/rest/v1/EventType)

### Elixir Libraries

- [Goth v1.4.5 (hex.pm)](https://hex.pm/packages/goth) -- Google OAuth2 service account auth
- [Goth.Token docs](https://hexdocs.pm/goth/Goth.Token.html)
- [google_api_drive v0.32 (hexdocs)](https://hexdocs.pm/google_api_drive/GoogleApi.Drive.V3.Api.Files.html)
- [Joken v2.6 (hex.pm)](https://hex.pm/packages/joken) -- JWT library
- [JOSE (GitHub)](https://github.com/potatosalad/erlang-jose) -- JSON Object Signing and Encryption
- [Req v0.5 (hex.pm)](https://hex.pm/packages/req) -- HTTP client

### Elixir Community

- [Using Joken to validate Google JWTs (ElixirForum)](https://elixirforum.com/t/using-joken-to-validate-google-jwts/19728)
- [Verify RS256 JWT with Joken.Signer (ElixirForum)](https://elixirforum.com/t/how-to-verify-rs256-jwt-with-joken-signer-verify-2-2022/51924)

---

## Self-Verification Checklist

- [x] All sources are authoritative (Google official docs, hexdocs)
- [x] Version numbers explicitly stated (Goth 1.4.5, google_api_drive 0.32, Joken 2.6)
- [x] Security implications documented (JWT verification, credential handling, file access)
- [x] Alternative approaches presented (JOSE direct vs Joken for JWT)
- [x] Dependencies verified against mix.exs (goth, req, google_api_drive present; joken absent but JOSE available transitively)
- [x] API endpoints, payload shapes, and auth flows specified for implementers
- [x] 30-second timeout constraint and async reply pattern documented
- [x] Coding wave order with dependency analysis provided
- [x] Every new file/module listed with its purpose
