# Architecture: Google Workspace Sync Engine + Multi-Channel Abstraction

> **Status**: Planning consultation (no implementation)
> **Date**: 2026-03-02
> **Scope**: Two feature streams — local workspace sync and multi-channel communication

---

## 1. Executive Summary

This document proposes the architecture for two major feature streams:

**Stream 1 — Google Workspace Local Sync**: A bidirectional sync engine that downloads Google Docs as Markdown and Google Sheets as CSV into a local workspace directory, keeps them in sync, and pushes local edits back to Google Drive. This builds on top of the existing `Drive` integration and `Drive.Scoping` modules.

**Stream 2 — Multi-Channel Communication**: Extending the existing `Channels.Adapter` behaviour to support Telegram, WhatsApp, and Slack alongside the existing Google Chat adapter. This requires a channel registry, per-channel webhook controllers, and channel-specific capability negotiation.

Both streams share a common concern: **per-user identity threading**. The existing `user_id` and `google_token` patterns in `Skills.Context` provide the foundation.

---

## 2. System Context (C4 Level 1)

```
                    +-----------------+
                    |   Chat User     |
                    | (Telegram/Slack |
                    |  WhatsApp/GChat)|
                    +--------+--------+
                             |
              Webhook/Bot API events
                             |
                             v
+------------------+   +-----------+   +------------------+
| Google Drive API |<->| Synaptic  |<->| Telegram Bot API |
| (Docs, Sheets)   |   | Assistant |   | Slack Events API |
+------------------+   +-----+-----+   | WhatsApp Cloud   |
                             |          +------------------+
                             |
                        +----+----+
                        | Local   |
                        |Workspace|
                        | (disk)  |
                        +---------+
```

---

## 3. Stream 1: Google Workspace Sync Engine

### 3.1 Design Decisions

#### ADR-SYNC-1: Hybrid Sync Strategy (Push + Periodic Poll)

**Decision**: Use Google Drive Changes API (push notifications via webhooks) as the primary sync trigger, with a periodic Oban poll as a fallback/reconciliation mechanism.

**Rationale**:
- Pure polling wastes API quota and introduces latency
- Pure push misses events when webhooks fail (Google does not guarantee delivery)
- The hybrid approach gives near-real-time sync with guaranteed eventual consistency
- Google Drive Changes API uses a `startPageToken` cursor model that is efficient for incremental sync

**Consequences**:
- Need a webhook endpoint for Drive push notifications (`/webhooks/drive-changes`)
- Need an Oban cron job for periodic reconciliation (every 5-10 minutes)
- Must store `startPageToken` per user in the database

#### ADR-SYNC-2: File-Level Sync Granularity

**Decision**: Sync at file-level granularity (whole file download/upload), not block-level.

**Rationale**:
- Google Docs API does not expose block-level diffs natively
- Google Sheets API allows cell-level access, but the complexity of partial sync is extreme
- File-level is simpler, more reliable, and sufficient for the use case
- Export formats (Markdown, CSV) are complete representations, not partial views

**Consequences**:
- Larger data transfers on each sync
- Conflict detection operates on whole-file modified timestamps, not fine-grained changes
- Acceptable trade-off for v1; block-level can be added later for Sheets if needed

#### ADR-SYNC-3: Conflict Resolution — Last-Write-Wins with Detection

**Decision**: Use last-write-wins (LWW) as the default conflict resolution strategy, with conflict detection that alerts the user when both sides changed since last sync.

**Rationale**:
- Three-way merge for Markdown/CSV is complex and error-prone
- User-decides workflows block the sync pipeline and require a UI
- LWW is simple and predictable; conflict detection prevents silent data loss
- The assistant can notify the user via their chat channel when a conflict is detected

**Consequences**:
- Store `remote_modified_at` and `local_modified_at` per synced file
- On conflict (both changed since last sync), create a `.conflict` copy of the losing version
- Notify user via their active chat channel: "Conflict detected in {filename} — local version saved as {filename}.conflict"

#### ADR-SYNC-4: Local Storage — Filesystem with Ecto Metadata

**Decision**: Store synced files on the local filesystem in a per-user workspace directory. Track sync metadata (file mapping, timestamps, tokens) in PostgreSQL via Ecto.

**Rationale**:
- Files on disk allow direct manipulation by the user and other tools
- Ecto metadata enables efficient sync state queries and conflict detection
- SQLite would add another database engine; PostgreSQL is already available
- The existing `workspace_path` field in `Skills.Context` provides a natural hook

**Consequences**:
- Workspace directory: `{workspace_root}/{user_id}/sync/` (configurable)
- Ecto schemas track file-to-drive-id mappings and sync state
- Must handle filesystem permissions and disk space

### 3.2 Component Architecture (C4 Level 3)

```
+------------------------------------------------------------------+
|                         Sync Engine                               |
|                                                                   |
|  +---------------------+    +---------------------+              |
|  | Sync.Coordinator    |    | Sync.FileManager    |              |
|  | (per-user GenServer)|    | (fs read/write)     |              |
|  |                     |--->|                      |              |
|  | - start/stop sync   |    | - write_local/3     |              |
|  | - schedule next     |    | - read_local/2      |              |
|  | - conflict detect   |    | - delete_local/2    |              |
|  +----------+----------+    | - ensure_dir/1      |              |
|             |               +---------------------+              |
|             v                                                     |
|  +---------------------+    +---------------------+              |
|  | Sync.ChangeDetector |    | Sync.Converter      |              |
|  | (diff engine)       |    | (format transforms) |              |
|  |                     |    |                      |              |
|  | - remote_changes/2  |    | - doc_to_markdown/1 |              |
|  | - local_changes/2   |    | - sheet_to_csv/1    |              |
|  | - detect_conflicts/2|    | - markdown_to_doc/1 |              |
|  +---------------------+    | - csv_to_sheet/1    |              |
|                              +---------------------+              |
|                                                                   |
|  +---------------------+    +---------------------+              |
|  | Sync.StateStore     |    | Sync.Workers        |              |
|  | (Ecto context)      |    | (Oban jobs)         |              |
|  |                     |    |                      |              |
|  | - get_sync_state/1  |    | SyncPollWorker      |              |
|  | - update_cursor/2   |    | SyncPushWorker      |              |
|  | - mark_synced/2     |    | ConflictNotifyWorker|              |
|  +---------------------+    +---------------------+              |
+------------------------------------------------------------------+
         |                            |
         v                            v
+------------------+     +------------------------+
| Google Drive API |     | Channels (notification)|
| (existing module)|     | (conflict alerts)      |
+------------------+     +------------------------+
```

### 3.3 Data Architecture

#### New Schemas

**`synced_files`** — Tracks the mapping between a Google Drive file and its local copy.

| Column | Type | Description |
|--------|------|-------------|
| `id` | `binary_id` | Primary key |
| `user_id` | `binary_id` (FK → users) | Owner |
| `drive_file_id` | `string` | Google Drive file ID |
| `drive_file_name` | `string` | Original filename in Drive |
| `drive_mime_type` | `string` | Google MIME type (e.g., `application/vnd.google-apps.document`) |
| `local_path` | `string` | Relative path within user's sync directory |
| `local_format` | `string` | Export format: `md`, `csv`, `txt` |
| `remote_modified_at` | `utc_datetime_usec` | Last known `modifiedTime` from Drive |
| `local_modified_at` | `utc_datetime_usec` | Last known mtime of local file |
| `remote_checksum` | `string` | SHA-256 of last downloaded content |
| `local_checksum` | `string` | SHA-256 of last known local content |
| `sync_status` | `string` | `synced`, `local_ahead`, `remote_ahead`, `conflict`, `error` |
| `last_synced_at` | `utc_datetime_usec` | Timestamp of last successful sync |
| `sync_error` | `text` | Last error message (nullable) |
| `drive_id` | `string` | Shared drive ID (nullable, nil for personal) |
| `inserted_at` | `utc_datetime_usec` | |
| `updated_at` | `utc_datetime_usec` | |

Indexes:
- `unique_index([:user_id, :drive_file_id])` — one sync record per file per user
- `index([:user_id, :sync_status])` — efficient conflict/error queries
- `index([:user_id, :local_path])` — local path lookup

**`sync_cursors`** — Tracks the Google Drive Changes API cursor per user.

| Column | Type | Description |
|--------|------|-------------|
| `id` | `binary_id` | Primary key |
| `user_id` | `binary_id` (FK → users) | Owner |
| `drive_id` | `string` | Shared drive ID (nullable, nil for personal) |
| `start_page_token` | `string` | Google Drive Changes API cursor |
| `last_poll_at` | `utc_datetime_usec` | Last poll timestamp |
| `inserted_at` | `utc_datetime_usec` | |
| `updated_at` | `utc_datetime_usec` | |

Index: `unique_index([:user_id, :drive_id])` (same partial index pattern as `connected_drives`)

### 3.4 Data Flow: Sync Cycle

#### Remote → Local (Download)

```
1. SyncPollWorker fires (Oban cron, every 5 min)
   OR Drive push notification arrives at /webhooks/drive-changes
       |
2. Sync.Coordinator.sync_user(user_id)
       |
3. For each enabled drive scope (from ConnectedDrives):
   a. Fetch changes since startPageToken via Drive.changes_list/3
   b. Filter to files in user's sync set (synced_files table)
       |
4. For each changed file:
   a. Sync.ChangeDetector.detect_conflicts(synced_file, remote_change)
   b. If conflict → create .conflict copy, notify user, skip
   c. If remote_ahead → download & convert:
      - Google Doc → Drive.export(token, id, "text/markdown") → Sync.Converter.doc_to_markdown/1
      - Google Sheet → Drive.export(token, id, "text/csv") → Sync.Converter.sheet_to_csv/1
   d. Sync.FileManager.write_local(user_workspace, local_path, content)
   e. Sync.StateStore.mark_synced(synced_file, %{remote_modified_at: ..., remote_checksum: ...})
       |
5. Update sync_cursors.start_page_token for next poll
```

#### Local → Remote (Upload)

```
1. SyncPollWorker detects local file changes (mtime + checksum comparison)
   OR future: fsnotify watcher triggers
       |
2. For each locally modified file:
   a. Sync.ChangeDetector.detect_conflicts(synced_file, local_change)
   b. If conflict → create .conflict copy, notify user, skip
   c. If local_ahead:
      - Markdown → Drive.update_file_content(token, id, content, "text/markdown")
      - CSV → Drive.update_file_content(token, id, content, "text/csv")
      NOTE: Google Workspace files (Docs, Sheets) cannot be updated via simple upload.
            For Docs: use Google Docs API batchUpdate (insert/delete/replace text ops).
            For Sheets: use Google Sheets API batchUpdate (update cell values).
            This is a significant complexity factor — see Risk Assessment.
   d. Sync.StateStore.mark_synced(synced_file, %{local_modified_at: ..., local_checksum: ...})
```

### 3.5 Integration with Existing Code

**Drive module extension**: Add `changes_list/3` and `watch_changes/3` to `Assistant.Integrations.Google.Drive`. These follow the existing pattern (accept `access_token` as first param, return normalized maps).

**Skills.Context extension**: Add `:sync_workspace_path` to `Skills.Context` to provide sync-aware skills with the sync directory path.

**Drive.Scoping reuse**: The sync engine iterates over `ConnectedDrives.enabled_for_user/1` scopes, exactly like `files.search` does today.

**Oban integration**: New queue `:sync` with `SyncPollWorker` (cron) and `SyncPushWorker` (on-demand). Follows existing patterns from `PendingIntentWorker` and `AuthTokenCleanupWorker`.

### 3.6 Bidirectional Upload Complexity

Uploading back to Google Workspace files (Docs, Sheets) is significantly more complex than downloading:

- **Google Docs**: Cannot simply upload Markdown. Must use the Google Docs API `batchUpdate` with structured requests (InsertTextRequest, DeleteContentRangeRequest). A Markdown-to-Docs translator is needed.
- **Google Sheets**: Cannot simply upload CSV. Must use the Google Sheets API `spreadsheets.values.update` to write cell ranges. A CSV-to-Sheets mapper is needed.
- **Non-Workspace files** (plain text, PDFs uploaded to Drive): Can use `Drive.update_file_content/4` directly.

**Recommendation**: Phase the implementation:
1. **Phase A**: Download-only sync (remote → local). Immediate value, low complexity.
2. **Phase B**: Upload for non-Workspace files (Markdown files created locally → Drive as plain text).
3. **Phase C**: Upload for Workspace files (Markdown → Docs API, CSV → Sheets API). High complexity, may require dedicated Docs/Sheets API client modules.

---

## 4. Stream 2: Multi-Channel Communication

### 4.1 Design Decisions

#### ADR-CHAN-1: Extend Existing Adapter Behaviour (Not Plugin Architecture)

**Decision**: Extend the existing `Channels.Adapter` behaviour with additional optional callbacks rather than introducing a plugin system.

**Rationale**:
- The existing behaviour (`normalize/1`, `send_reply/3`, `channel_name/0`) is clean and minimal
- A plugin architecture adds dynamic loading complexity that is not needed for a known, finite set of channels
- Adapters are compile-time modules, which enables dialyzer checks and pattern matching
- The existing pattern works well for Google Chat; new channels follow the same shape

**Consequences**:
- New adapters are modules implementing `Channels.Adapter`
- Optional callbacks added for channel-specific capabilities (typing indicators, rich messages, reactions)
- A `Channels.Registry` module maps channel atoms to adapter modules

#### ADR-CHAN-2: Unified Message Format with Channel Capabilities

**Decision**: Keep the existing `Channels.Message` struct as the unified format. Extend it with an optional `capabilities` map on the adapter for channel-specific features, rather than a lowest-common-denominator approach.

**Rationale**:
- The current `Message` struct already captures the universal fields well
- Channel-specific features (Slack threads, Telegram inline keyboards, WhatsApp templates) should not bloat the core struct
- A capabilities-based approach lets the orchestrator query what a channel supports and adapt responses
- `metadata` map already exists for channel-specific data

**Consequences**:
- Core struct stays lean; channel-specific data goes in `metadata`
- New optional callback `capabilities/0` returns supported features (`:typing`, `:reactions`, `:rich_cards`, `:threads`, `:inline_keyboards`, etc.)
- The orchestrator can check capabilities to decide response format (e.g., send a card if supported, plain text otherwise)

#### ADR-CHAN-3: Per-Channel Webhook Controllers with Shared Dispatch

**Decision**: Each channel gets its own controller module (like `GoogleChatController`) with channel-specific auth, but all controllers dispatch to a shared `Channels.Dispatcher` module.

**Rationale**:
- Webhook authentication is channel-specific (JWT for Google Chat, token validation for Telegram, request signing for Slack)
- The async processing pattern (normalize → dispatch → process → reply) is identical across channels
- Extracting shared dispatch logic prevents duplication of the conversation engine integration

**Consequences**:
- `AssistantWeb.TelegramController`, `AssistantWeb.SlackController`, `AssistantWeb.WhatsAppController`
- `Assistant.Channels.Dispatcher` handles the shared normalize → engine → reply flow
- Each controller handles only auth verification and raw payload extraction

#### ADR-CHAN-4: Channel-Specific OAuth Onboarding

**Decision**: Use OAuth where available (Slack, potentially WhatsApp Business), bot token registration for Telegram, and store channel credentials encrypted in the database.

**Rationale**:
- Slack requires OAuth2 for workspace installations (Events API subscription)
- Telegram uses a simple bot token (no OAuth, just a token from BotFather)
- WhatsApp Cloud API uses a System User token or OAuth from Meta Business
- Credentials must be encrypted at rest (following the existing `Encrypted.Binary` pattern)

### 4.2 Component Architecture (C4 Level 3)

```
+------------------------------------------------------------------+
|                      Channel Layer                                |
|                                                                   |
|  +-------------------+  +-------------------+                    |
|  | Channels.Registry |  | Channels.         |                    |
|  | (atom → module)   |  | Dispatcher        |                    |
|  |                   |  | (shared flow)     |                    |
|  | :google_chat →    |  |                   |                    |
|  |   GoogleChat      |  | - dispatch/2      |                    |
|  | :telegram →       |  | - ensure_engine/2 |                    |
|  |   Telegram        |  | - process_reply/2 |                    |
|  | :slack → Slack    |  +-------------------+                    |
|  | :whatsapp →       |           |                                |
|  |   WhatsApp        |           v                                |
|  +-------------------+  +-------------------+                    |
|                          | Orchestrator      |                    |
|  Adapters:               | Engine            |                    |
|  +-------------------+  +-------------------+                    |
|  | Channels.Telegram |                                           |
|  | Channels.Slack    |  Per-adapter webhook controllers:         |
|  | Channels.WhatsApp |  +-------------------+                    |
|  | Channels.GoogleChat| | TelegramController|                    |
|  +-------------------+  | SlackController   |                    |
|                          | WhatsAppController|                    |
|                          | GoogleChatCtrl    |                    |
|                          +-------------------+                    |
+------------------------------------------------------------------+
```

### 4.3 Adapter Behaviour Extension

The existing `Channels.Adapter` behaviour needs these additions:

```elixir
# Existing callbacks (unchanged):
@callback channel_name() :: atom()
@callback normalize(raw_event :: map()) :: {:ok, Message.t()} | {:error, term()}
@callback send_reply(space_id :: String.t(), text :: String.t(), opts :: keyword()) ::
            :ok | {:error, term()}

# New optional callbacks:
@callback capabilities() :: [atom()]
@callback send_typing(space_id :: String.t()) :: :ok | {:error, term()}
@callback send_rich_message(space_id :: String.t(), card :: map(), opts :: keyword()) ::
            :ok | {:error, term()}
@callback setup_webhook(config :: map()) :: {:ok, webhook_info :: map()} | {:error, term()}
@callback verify_webhook(conn :: Plug.Conn.t(), config :: map()) ::
            {:ok, Plug.Conn.t()} | {:error, term()}
```

Optional callbacks use `@optional_callbacks` so adapters only implement what they support.

### 4.4 Channel Registry

```elixir
defmodule Assistant.Channels.Registry do
  @adapters %{
    google_chat: Assistant.Channels.GoogleChat,
    telegram: Assistant.Channels.Telegram,
    slack: Assistant.Channels.Slack,
    whatsapp: Assistant.Channels.WhatsApp
  }

  def adapter_for(channel), do: Map.get(@adapters, channel)
  def all_channels, do: Map.keys(@adapters)
  def enabled_channels, do: ...  # Check config for which are configured
end
```

### 4.5 Shared Dispatcher

The `GoogleChatController` currently contains shared logic (conversation engine startup, async processing, reply sending) that should be extracted:

```elixir
defmodule Assistant.Channels.Dispatcher do
  @doc "Normalize, dispatch to engine, and send reply. Async."
  def dispatch(adapter, raw_event, opts \\ []) do
    case adapter.normalize(raw_event) do
      {:ok, message} ->
        Task.Supervisor.start_child(
          Assistant.Skills.TaskSupervisor,
          fn -> process_and_reply(adapter, message, opts) end
        )
        {:ok, :dispatched}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp process_and_reply(adapter, message, _opts) do
    conversation_id = derive_conversation_id(message)
    ensure_engine_started(conversation_id, message)

    case Engine.send_message(conversation_id, message.content) do
      {:ok, response} -> adapter.send_reply(message.space_id, response, reply_opts(message))
      {:error, _} -> adapter.send_reply(message.space_id, error_message(), reply_opts(message))
    end
  end

  defp derive_conversation_id(message) do
    base = "#{message.channel}:#{message.space_id}"
    if message.thread_id, do: "#{base}:#{message.thread_id}", else: base
  end
end
```

This extracts the pattern currently hardcoded in `GoogleChatController`, making it reusable for all channels.

### 4.6 Channel-Specific Details

#### Telegram

- **Auth**: Bot token from BotFather, stored in config or DB
- **Webhook**: POST `/webhooks/telegram` — Telegram sends updates to this endpoint
- **Webhook verification**: Compare `X-Telegram-Bot-Api-Secret-Token` header against configured secret
- **Message mapping**: `update.message.text` → `Message.content`, `update.message.chat.id` → `Message.space_id`
- **Reply**: `POST https://api.telegram.org/bot{token}/sendMessage` with `chat_id` and `text`
- **Capabilities**: `:typing` (sendChatAction), `:inline_keyboards`, `:markdown_formatting`
- **User identification**: `update.message.from.id` → `Message.user_id`

#### Slack

- **Auth**: OAuth2 workspace install (bot token + signing secret)
- **Webhook**: POST `/webhooks/slack` — Slack Events API
- **Webhook verification**: Validate `X-Slack-Signature` using signing secret (HMAC-SHA256)
- **URL verification**: Must respond to `url_verification` challenge event
- **Message mapping**: `event.text` → `Message.content`, `event.channel` → `Message.space_id`
- **Reply**: `POST https://slack.com/api/chat.postMessage` with `channel` and `text`
- **Capabilities**: `:typing`, `:threads`, `:reactions`, `:rich_cards` (Block Kit), `:markdown_formatting`
- **User identification**: `event.user` → `Message.user_id`
- **Special**: Must handle `app_mention` and `message` event types differently

#### WhatsApp (Cloud API)

- **Auth**: System User token from Meta Business Manager or OAuth
- **Webhook**: POST `/webhooks/whatsapp` — Meta Webhooks
- **Webhook verification**: GET request with `hub.verify_token` challenge (initial), POST with HMAC signature
- **Message mapping**: `entry[0].changes[0].value.messages[0].text.body` → `Message.content`
- **Reply**: `POST https://graph.facebook.com/v18.0/{phone_number_id}/messages`
- **Capabilities**: `:templates`, `:media_messages`, `:reactions`
- **User identification**: `messages[0].from` (phone number) → `Message.user_id`
- **Special**: 24-hour messaging window — after 24h without user message, must use templates

### 4.7 Channel Configuration Schema

**`channel_configs`** — Stores per-channel configuration and credentials.

| Column | Type | Description |
|--------|------|-------------|
| `id` | `binary_id` | Primary key |
| `channel` | `string` | Channel atom as string: `telegram`, `slack`, `whatsapp` |
| `config` | `map` (JSONB) | Non-sensitive config (webhook URL, workspace name) |
| `credentials` | `Encrypted.Binary` | Encrypted JSON blob (bot tokens, signing secrets, OAuth tokens) |
| `enabled` | `boolean` | Whether the channel is active |
| `webhook_url` | `string` | Registered webhook URL (nullable) |
| `webhook_status` | `string` | `active`, `pending`, `failed` |
| `inserted_at` | `utc_datetime_usec` | |
| `updated_at` | `utc_datetime_usec` | |

Index: `unique_index([:channel])` — one config per channel

### 4.8 User Identity Bridging

A critical concern: users may interact via multiple channels. The `users` table currently uses `(external_id, channel)` as the unique identifier, meaning the same person on Telegram and Slack would be two separate users.

**Options**:

A) **Keep separate identities per channel** (recommended for v1)
   - Simpler, no cross-channel linking needed
   - Each channel has its own user record
   - OAuth tokens, preferences are per-channel-user
   - Trade-off: No unified conversation history across channels

B) **Cross-channel identity linking** (future)
   - Add `identity_group_id` to users table
   - Users can link accounts via settings dashboard
   - Shared OAuth tokens, preferences, conversation history
   - Significant complexity, especially for token scoping

**Recommendation**: Start with A, design schemas to support future migration to B.

---

## 5. Shared Concerns

### 5.1 Webhook Security

| Channel | Verification Method | Implementation |
|---------|---------------------|----------------|
| Google Chat | JWT signature (existing `GoogleChatAuth` plug) | Already implemented |
| Telegram | `X-Telegram-Bot-Api-Secret-Token` header match | New plug: `TelegramAuth` |
| Slack | `X-Slack-Signature` HMAC-SHA256 validation | New plug: `SlackAuth` |
| WhatsApp | `X-Hub-Signature-256` HMAC-SHA256 validation | New plug: `WhatsAppAuth` |
| Drive Changes | Channel ID + token validation | New plug: `DriveChangesAuth` |

Each auth plug follows the existing pattern from `AssistantWeb.Plugs.GoogleChatAuth`:
- Plug in the router pipeline for the specific scope
- Return 401 on verification failure
- Pass through on success

### 5.2 Rate Limiting

All webhook endpoints should have rate limiting to prevent abuse:
- Use `PlugAttack` or a simple token bucket in ETS
- Per-IP and per-channel limits
- Google Chat already has implicit rate limiting via JWT verification overhead

### 5.3 Error Handling and Resilience

Both streams need resilient error handling:

**Sync Engine**:
- Token refresh failures → skip sync cycle, retry next poll
- API quota exhaustion → exponential backoff via Oban retry
- Filesystem errors → mark file as `error` status, alert user
- Network failures → Oban auto-retry with backoff

**Channel Layer**:
- Webhook processing failures → return 200 (acknowledge receipt), log error, alert
- Reply send failures → retry via Oban job (not inline retry)
- Engine startup failures → send error message to user via channel

---

## 6. Module Organization

### 6.1 New Modules — Sync Engine

```
lib/assistant/
  sync/
    coordinator.ex         # Per-user sync GenServer
    change_detector.ex     # Conflict detection logic
    converter.ex           # Format conversion (Doc↔MD, Sheet↔CSV)
    file_manager.ex        # Local filesystem operations
    state_store.ex         # Ecto context for sync state
    workers/
      sync_poll_worker.ex  # Oban cron: periodic reconciliation
      sync_push_worker.ex  # Oban: process Drive push notification
      conflict_notify_worker.ex  # Oban: notify user of conflicts
  schemas/
    synced_file.ex         # Ecto schema
    sync_cursor.ex         # Ecto schema
  integrations/google/
    drive.ex               # (existing — add changes_list/3, watch_changes/3)
    drive/
      scoping.ex           # (existing — unchanged)
      changes.ex           # New: Changes API wrapper
```

### 6.2 New Modules — Channel Layer

```
lib/assistant/
  channels/
    adapter.ex             # (existing — extend with optional callbacks)
    message.ex             # (existing — unchanged)
    google_chat.ex         # (existing — unchanged)
    telegram.ex            # New adapter
    slack.ex               # New adapter
    whatsapp.ex            # New adapter
    registry.ex            # New: channel atom → module mapping
    dispatcher.ex          # New: shared dispatch logic (extracted from GoogleChatController)
  schemas/
    channel_config.ex      # New: per-channel configuration
lib/assistant_web/
  controllers/
    google_chat_controller.ex  # (existing — refactor to use Dispatcher)
    telegram_controller.ex     # New webhook controller
    slack_controller.ex        # New webhook controller
    whatsapp_controller.ex     # New webhook controller
    drive_changes_controller.ex # New: Drive push notification handler
  plugs/
    google_chat_auth.ex    # (existing)
    telegram_auth.ex       # New
    slack_auth.ex          # New
    whatsapp_auth.ex       # New
```

### 6.3 Router Additions

```elixir
# Drive Changes push notifications
scope "/webhooks", AssistantWeb do
  pipe_through :api
  post "/drive-changes", DriveChangesController, :event
end

# Telegram (already has placeholder)
scope "/webhooks", AssistantWeb do
  pipe_through [:api, :telegram_auth]
  post "/telegram", TelegramController, :event
end

# Slack
scope "/webhooks", AssistantWeb do
  pipe_through [:api, :slack_auth]
  post "/slack", SlackController, :event
end

# WhatsApp
scope "/webhooks", AssistantWeb do
  pipe_through [:api, :whatsapp_auth]
  post "/whatsapp", WhatsAppController, :event
  get "/whatsapp", WhatsAppController, :verify  # URL verification challenge
end
```

---

## 7. Technology Decisions

| Component | Choice | Rationale |
|-----------|--------|-----------|
| Async job processing | Oban (existing) | Already in use; proven patterns for workers |
| Local file sync | Filesystem + Ecto metadata | Files on disk for direct access; Ecto for state tracking |
| Format conversion | Custom Elixir modules | Google export APIs handle Docs→text; light post-processing for MD/CSV |
| Webhook auth | Per-channel Plug middleware | Follows existing GoogleChatAuth pattern |
| Channel credentials | `Encrypted.Binary` (Cloak) | Follows existing OAuth token encryption pattern |
| Drive change detection | Drive Changes API + Oban cron | Hybrid push+poll for reliability |
| Conflict resolution | Last-write-wins + detection | Simple, predictable, user-notified |

---

## 8. Security Architecture

### 8.1 Sync Engine Security

- **Token isolation**: Per-user OAuth tokens (existing `Auth.user_token/1`) ensure users can only sync their own files
- **Path validation**: `Sync.FileManager` must validate paths to prevent directory traversal (following the pattern in `Workflow.Helpers.resolve_path/1`)
- **Filesystem permissions**: Workspace directories created with restrictive permissions (0700)
- **Drive scoping**: Sync engine respects `ConnectedDrives.enabled_for_user/1` — only syncs files from authorized drives

### 8.2 Channel Security

- **Webhook verification**: Each channel has its own auth plug (see section 5.1)
- **Credential encryption**: All channel tokens stored using `Encrypted.Binary`
- **Input sanitization**: All channel-normalized messages go through the existing orchestrator pipeline
- **Rate limiting**: Per-channel webhook rate limits prevent abuse

---

## 9. Implementation Roadmap

### Phase 1: Channel Abstraction Foundation (recommended first)

**Why first**: Lower complexity, immediately useful, enables user communication for sync notifications.

1. Extract `Channels.Dispatcher` from `GoogleChatController`
2. Create `Channels.Registry`
3. Add optional callbacks to `Channels.Adapter`
4. Refactor `GoogleChatController` to use Dispatcher
5. Implement `Channels.Telegram` adapter + controller
6. Create `channel_configs` migration and schema

**Effort estimate**: Medium (well-understood patterns, existing adapter to follow)

### Phase 2: Telegram + Slack Channels

1. Implement Telegram webhook auth plug
2. Complete Telegram adapter (normalize, send_reply, capabilities)
3. Settings UI: Telegram bot token configuration
4. Implement Slack OAuth2 workspace install flow
5. Implement Slack adapter + webhook auth plug
6. Settings UI: Slack workspace connection

**Effort estimate**: Medium-High (Slack OAuth adds complexity)

### Phase 3: Sync Engine — Download Only

1. Create `synced_files` and `sync_cursors` migrations
2. Implement `Drive.Changes` API wrapper
3. Build `Sync.Converter` (doc→markdown, sheet→csv)
4. Build `Sync.FileManager` (filesystem operations with path validation)
5. Build `Sync.StateStore` (Ecto context)
6. Build `Sync.ChangeDetector` (conflict detection)
7. Build `SyncPollWorker` (Oban cron)
8. Settings UI: sync configuration (which files/folders to sync)

**Effort estimate**: High (new domain, API integration, filesystem management)

### Phase 4: Sync Engine — Bidirectional

1. Implement local change detection (mtime + checksum)
2. Build upload for non-Workspace files
3. Investigate and build Docs API integration for Markdown → Doc
4. Investigate and build Sheets API integration for CSV → Sheet
5. Build `Sync.Coordinator` GenServer for per-user sync orchestration
6. Drive push notifications webhook

**Effort estimate**: Very High (Google Docs/Sheets API complexity)

### Phase 5: WhatsApp + Polish

1. Implement WhatsApp Cloud API adapter
2. WhatsApp webhook verification
3. 24-hour messaging window handling
4. Cross-channel identity linking (if needed)
5. Sync conflict resolution UI in settings dashboard

**Effort estimate**: Medium (WhatsApp has good documentation)

---

## 10. Risk Assessment

### High Risk

| Risk | Impact | Mitigation |
|------|--------|------------|
| **Google Docs/Sheets upload complexity** | Bidirectional sync for Workspace files requires separate APIs (Docs API, Sheets API) with structured update operations. Converting Markdown → Docs `batchUpdate` is non-trivial. | Phase the work: download-only first (Phase 3), upload for plain files (Phase 4a), Workspace upload last (Phase 4b). Consider third-party libraries for Markdown→Docs conversion. |
| **Sync conflict data loss** | LWW can overwrite user changes. Even with conflict detection, the `.conflict` file may be missed. | Always create conflict copies before overwriting. Push conflict notifications through active chat channel. Add conflict resolution UI. |
| **Google Drive API quota exhaustion** | Polling + push + file operations can hit quota limits, especially for users with many files. | Use Drive Changes API (efficient, returns only deltas). Implement exponential backoff. Allow users to configure sync frequency. Monitor quota usage. |

### Medium Risk

| Risk | Impact | Mitigation |
|------|--------|------------|
| **Slack OAuth complexity** | Workspace-level OAuth with scopes, bot tokens, and signing secrets is more complex than other channels. | Follow Slack's official Bolt framework patterns. Use existing PKCE patterns from OpenRouter OAuth. |
| **WhatsApp 24-hour window** | Messages fail after 24h without user response. Templates required for re-engagement. | Track last user message timestamp per conversation. Auto-switch to template messages when window expires. Inform users about limitations. |
| **Filesystem reliability** | Disk full, permission errors, symlink attacks, concurrent access from other tools. | Validate paths (no traversal). Check disk space before writes. Use atomic write (write to temp, rename). Restrict permissions. |
| **Channel abstraction becoming too thin** | If adapters are too thin, channel-specific features get lost. If too thick, the abstraction leaks. | The capabilities pattern allows progressive enhancement. Core is thin (normalize + reply), optional callbacks for rich features. |

### Low Risk

| Risk | Impact | Mitigation |
|------|--------|------------|
| **Telegram integration** | Well-documented, simple API, widely used in Elixir ecosystem. | Straightforward implementation following existing adapter pattern. |
| **Database schema additions** | New tables (`synced_files`, `sync_cursors`, `channel_configs`) are additive. | Standard Ecto migrations. No changes to existing tables. |

---

## 11. Open Questions

1. **Sync scope selection**: How does the user select which files/folders to sync? Options:
   - Sync entire enabled drives (may be too much)
   - Sync specific folders (user picks in settings UI)
   - Sync files matching a pattern (e.g., all Docs in a "Workspace" folder)

2. **Workspace directory location**: Where should the sync workspace live?
   - Configurable via environment variable / settings
   - Default: `{app_data}/workspaces/{user_id}/sync/`
   - Must be accessible to the user if they want to edit files directly

3. **Google Docs → Markdown fidelity**: Google's export-as-Markdown preserves basic formatting but loses complex features (tables, images, comments). Is this acceptable?
   - For v1, yes — Markdown export covers the primary use case
   - Future: consider richer export formats if needed

4. **Multiple chat channels per user**: If a user has both Telegram and Slack, which channel receives sync conflict notifications?
   - Use the channel they most recently sent a message from (track `last_active_channel` on user)
   - Or allow users to set a preferred notification channel in settings

5. **Self-hosted deployment**: Do sync workspace paths and webhook URLs need special handling for self-hosted instances?
   - Webhook URLs must be publicly accessible (or use ngrok/tunneling for dev)
   - Workspace paths are local to the server (not a concern for single-server deployments)
