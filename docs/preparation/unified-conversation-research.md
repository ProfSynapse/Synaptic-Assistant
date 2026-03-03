# Research: Unified Cross-Channel Conversation Architecture

> **Date**: 2026-03-03 (updated with user clarification)
> **Phase**: PREPARE
> **Scope**: Map the current conversation and user identity architecture, identify gaps for unified cross-channel conversations
>
> **User Clarification**: The desired model is ONE perpetual conversation per user. It never closes, never rotates. Messages from all channels flow into a single ongoing thread. The Engine doesn't need to "find or create" a conversation — it should just know it's talking to that user. Think: a single thread that never ends.

---

## Executive Summary

The current architecture has a **two-world problem**: the Engine/Dispatcher system uses ephemeral string-based conversation IDs (e.g., `telegram:6477961172`) that exist only in process memory, while the database has a fully-modeled `conversations` table with UUID primary keys, user foreign keys, and message persistence — but the two are **never connected**. Messages flow through the Engine's in-memory history and are never persisted to the `messages` table. Users are created only via settings-dashboard OAuth flows, not via channel message arrival. The conversation_id used by the Engine cannot be looked up as a conversation in the database.

To achieve unified cross-channel conversations, three fundamental bridges must be built: (1) a channel user-identity to DB user mapping, (2) an Engine that uses DB-backed conversation IDs, and (3) a reply-routing mechanism that knows which channel(s) a user is reachable on.

**User-confirmed model**: Each user has exactly ONE perpetual conversation that never closes. Messages from all channels flow into this single thread. The Engine is effectively keyed by user, not by conversation — there's a 1:1 mapping. Compaction is essential since the conversation grows without bound.

---

## 1. Current Architecture: Detailed Flow Maps

### 1.1 Message Ingestion Flow

```
Platform Webhook (HTTP POST)
    │
    ▼
Channel Controller (e.g., TelegramController)
    │  Extracts raw event params
    ▼
Channel Adapter (e.g., Channels.Telegram)
    │  normalize/1 → %Channels.Message{} struct
    │  Sets: channel, space_id, thread_id, user_id (platform-native),
    │        content, slash_command, metadata
    ▼
Dispatcher.dispatch(adapter, message)
    │  Spawns async Task under Skills.TaskSupervisor
    ▼
Dispatcher.process_and_reply(adapter, message)
    │
    ├─ derive_conversation_id(message)
    │    → "{channel}:{space_id}" or "{channel}:{space_id}:{thread_id}"
    │    → e.g., "telegram:6477961172" or "slack:T12345:C67890"
    │
    ├─ ensure_engine_started(conversation_id, message)
    │    → Checks EngineRegistry via GenServer.call
    │    → If not found: DynamicSupervisor.start_child with opts:
    │        [user_id: message.user_id, channel: to_string(message.channel), mode: :multi_agent]
    │    → NOTE: user_id here is the RAW PLATFORM ID (e.g., "6477961172" for Telegram)
    │           NOT a database UUID
    │
    ├─ Engine.send_message(conversation_id, message.content)
    │    → GenServer.call with 120s timeout
    │    → Runs LLM loop, sub-agent dispatch, returns response text
    │
    └─ adapter.send_reply(message.space_id, response_text, reply_opts)
         → Sends response back to originating platform
```

### 1.2 Engine Lifecycle & State

```
Engine GenServer State:
{
  conversation_id: "telegram:6477961172"     ← STRING, not a UUID
  user_id: "6477961172"                       ← RAW PLATFORM ID, not DB UUID
  channel: "telegram"                         ← string from message
  mode: :multi_agent
  messages: [                                 ← IN-MEMORY ONLY, never persisted to DB
    %{role: "user", content: "..."},
    %{role: "assistant", content: "..."}
  ]
  dispatched_agents: %{}
  ...
}

Engine is registered via:
  {:via, Registry, {Assistant.Orchestrator.EngineRegistry, "telegram:6477961172"}}

Engine lifetime: starts on first message, stays alive until process exits (no idle timeout shown).
```

### 1.3 Sub-Agent Conversation Hierarchy

```
Orchestrator Engine
  conversation_id: "telegram:6477961172"     ← parent (ephemeral string)
     │
     ├─ Sub-Agent 1
     │    conversation_id: "a1b2c3-uuid"      ← generated UUID (Ecto.UUID.generate())
     │    parent_conversation_id: "telegram:6477961172"  ← parent's ephemeral string
     │
     └─ Sub-Agent 2
          conversation_id: "d4e5f6-uuid"
          parent_conversation_id: "telegram:6477961172"
```

**Key observation**: Sub-agents generate real UUIDs for their `conversation_id`, but the parent is always the ephemeral string. The `Conversation.root_conversation_id/1` function assumes `parent_conversation_id` is a valid UUID — but it will never be one in the current flow because the root conversation is never a DB record.

### 1.4 Memory & Persistence Flow

```
After Engine.send_message completes:
    │
    ├─ broadcast_turn_completed → PubSub "memory:turn_completed"
    │    → TurnClassifier picks up, classifies turn
    │    → If save_facts: dispatches to Memory Agent
    │    → Memory Agent calls Store.create_memory_entry
    │       → source_conversation_id = "telegram:6477961172" (the ephemeral string!)
    │       → This is stored in memory_entries.source_conversation_id
    │       → BUT conversations table has UUID primary keys — FK will FAIL
    │       → (or be stored as a dangling reference if FK is nilify_all)
    │
    ├─ enqueue_trajectory_export → Oban job
    │    → conversation_id = "telegram:6477961172" (ephemeral string)
    │
    └─ enqueue_memory_saves → Oban MemorySaveWorker
         → conversation_id = "telegram:6477961172" (ephemeral string)
         → Stored in memory_entries.source_conversation_id
```

**Critical finding**: The `memory_entries.source_conversation_id` column has a FK reference to `conversations.id` (binary_id), but the Engine passes ephemeral string IDs like `"telegram:6477961172"`. This means either:
- The FK insert fails silently (if the column is nullable with `on_delete: :nilify_all`)
- The memory entries are saved with `source_conversation_id = nil`

### 1.5 Database Conversation Schema (Unused)

The `conversations` table and `Store.get_or_create_conversation/2` exist but are **never called** from any production code path. The Engine never creates DB conversations. The Store functions are "dead code" from the perspective of the current channel message flow.

```
conversations table:
  id: binary_id (UUID)
  user_id: references(users) NOT NULL    ← requires a valid DB user
  channel: text NOT NULL
  status: text (active|idle|closed)
  summary, summary_version, summary_model  ← compaction fields
  last_compacted_message_id
  agent_type: text (orchestrator|sub_agent)
  parent_conversation_id: self-reference

messages table:
  id: binary_id (UUID)
  conversation_id: references(conversations) NOT NULL
  role, content, tool_calls, tool_results, token_count
  parent_execution_id
```

### 1.6 User Identity Across Channels

**Current `users` table**:
```
users:
  id: binary_id (UUID)
  external_id: text NOT NULL          ← e.g., "settings:abc123-uuid" or platform ID
  channel: text NOT NULL              ← e.g., "settings", "telegram", "slack"
  display_name, timezone, preferences
  UNIQUE(external_id, channel)
```

**How users are created today**:
1. **Settings dashboard OAuth** (`SettingsLive.Context.ensure_linked_user/1`):
   - Creates user with `external_id: "settings:{settings_user_id}"`, `channel: "settings"`
   - Links to `settings_users` table via `settings_users.user_id` FK
2. **OpenAI OAuth callback** (`OpenAIOAuthController.ensure_linked_user/1`):
   - Same pattern as settings dashboard
3. **Google OAuth callback** (`OAuthController.maybe_link_settings_user/2`):
   - Looks up settings_user by email, links to existing chat user
4. **Channel message arrival**: **NO user creation happens.** The raw platform ID (e.g., `"6477961172"`) is passed as `user_id` but never looked up or created in the `users` table.

**Per-channel user_id formats** (set in `Channels.Message.user_id`):
| Channel | user_id Format | Example |
|---------|---------------|---------|
| Telegram | Raw numeric string | `"6477961172"` |
| Google Chat | GChat user resource name | `"users/123456789"` |
| Slack | Scoped `slack:{team}:{user}` | `"slack:T12345:U67890"` |
| Discord | Scoped `discord:{guild}:{user}` | `"discord:123:456"` |

**Cross-channel identity**: There is **no mechanism** to link a Telegram user to a Slack user. Each channel produces its own opaque user ID. The `users` table has a `UNIQUE(external_id, channel)` constraint, meaning the same person on two channels would be two separate user rows.

---

## 2. Gap Analysis: Current State vs. Desired State

### 2.1 Desired State Summary

1. Each human user has ONE central conversation (persisted in DB)
2. Messages from any channel feed into that single conversation
3. The bot knows which channel a message came from and responds on that channel
4. The bot can proactively send messages to OTHER channels (e.g., "send this to my Telegram")

### 2.2 Gap Matrix

| Capability | Current State | Desired State | Gap Severity |
|------------|--------------|---------------|-------------|
| **User identity resolution** | Raw platform IDs, no DB lookup | Platform ID → DB user (UUID) | HIGH — foundational |
| **Cross-channel user linking** | No mechanism | Single user entity across channels | HIGH — required for unified conversation |
| **DB conversation creation** | Never happens via channels | One perpetual conversation per user; created on first message, never closed | HIGH — required for persistence |
| **Message persistence** | In-memory only in Engine | Each message persisted to `messages` table | MEDIUM — needed for conversation history across sessions |
| **Engine conversation_id** | Ephemeral string (e.g., `telegram:123`) | DB conversation UUID | HIGH — must change for DB integration |
| **Memory entry FK integrity** | `source_conversation_id` receives invalid string | Valid UUID FK to `conversations` table | MEDIUM — currently broken silently |
| **Reply routing** | `adapter.send_reply(space_id, ...)` hardcoded per request | Route replies to any channel the user is connected to | HIGH — required for cross-channel |
| **Channel connection registry** | None | Track which channels a user is reachable on | HIGH — new capability needed |
| **Proactive messaging** | Not supported | Bot initiates messages to specific channels | MEDIUM — additive feature |
| **Session continuity** | Engine dies → conversation lost | Engine resumes from DB conversation state | MEDIUM — important for UX |

### 2.3 Detailed Gap Descriptions

#### GAP 1: User Identity Resolution (HIGH)

**Problem**: When a Telegram message arrives with `user_id: "6477961172"`, the Dispatcher passes this raw string to the Engine. Nothing checks whether a `users` row exists with `external_id = "6477961172" AND channel = "telegram"`. The Engine stores `"6477961172"` as its `user_id` state, but this is not a valid UUID and cannot be used to query user-scoped data (memory entries, tasks, OAuth tokens, connected drives).

**What's needed**: A "resolve or create user" step in the Dispatcher (or a new module) that:
1. Looks up `users` by `(external_id, channel)`
2. If not found, creates a new `users` row
3. Returns the DB user UUID
4. Passes this UUID (not the raw platform ID) to the Engine

#### GAP 2: Cross-Channel User Linking (HIGH)

**Problem**: A person who uses both Telegram and Slack would have two separate `users` rows with different UUIDs. Their conversations, memories, and tasks would be completely siloed.

**What's needed**: A mechanism to link multiple channel identities to a single logical user. Options include:
- A `user_identities` / `channel_identities` join table mapping `(user_id, channel, external_id)`
- Moving `external_id`/`channel` out of `users` into a separate table
- A "primary user" concept with linked secondary identities
- The `settings_users` table already has a `user_id` FK — this could serve as the linking point if the settings user has verified ownership of multiple channels

#### GAP 3: DB Conversation Lifecycle (HIGH)

**Problem**: `Store.get_or_create_conversation/2` exists but is never called. The Engine uses ephemeral string IDs. Conversations are not persisted and cannot survive Engine restarts.

**User clarification**: The model is ONE perpetual conversation per user. It never closes. Messages from all channels flow into this single thread. This simplifies the lifecycle considerably — no status transitions, no "find active" queries.

**What's needed**: The Dispatcher (or a new module) must:
1. After resolving the user, get the user's single conversation (create on first message)
2. Use the conversation UUID as the Engine's `conversation_id`
3. The Engine should persist messages to the DB via `Store.append_message/2`

**Implications of the perpetual model**:
- The `conversations.status` field (active/idle/closed) becomes less relevant — the conversation is always logically "active"
- The `conversations.channel` field is ambiguous — the conversation spans ALL channels. Could be set to "multi" or the channel of first contact, or removed entirely
- Compaction becomes essential — a single conversation will grow without bound, so the existing summary/compaction system must work well
- The `Store.get_or_create_conversation/2` function's query (find active conversation for user) still works but the `status == "active"` filter is always true since the conversation never closes
- The Engine's registration key could potentially be the **user_id** (UUID) rather than conversation_id, since there's a 1:1 mapping. This would simplify lookup: "is there an Engine running for this user?" rather than "find this user's conversation ID, then find the Engine for that conversation"

#### GAP 4: Engine Registration Key Change (HIGH)

**Problem**: The Engine registers with `EngineRegistry` using the ephemeral string ID. Switching to UUID-based conversation IDs means the registry key format changes.

**Impact**: This is a pervasive change — every call to `Engine.send_message/2`, `Engine.get_state/1`, and `via_tuple/1` uses the conversation_id.

**What's needed**: All Engine registration and lookup must use the DB conversation UUID. The `derive_conversation_id` function in the Dispatcher would be replaced by the DB-backed lookup.

#### GAP 5: Reply Routing (HIGH)

**Problem**: Currently, the adapter's `send_reply/3` is called directly with the `space_id` and `thread_id` from the incoming message. The Engine has no knowledge of where to send replies — the Dispatcher just calls back to the same adapter that received the message.

**What's needed for cross-channel replies**:
1. A "channel connection" registry: `user_channels` table tracking `(user_id, channel, space_id, active)`
2. When the bot wants to proactively message a user, it looks up their connected channels
3. A reply-routing layer that can send to any registered channel/space
4. The `send_reply` call needs to be abstracted — instead of `adapter.send_reply(space_id, text)`, it should be something like `ReplyRouter.send(user_id, text, opts)` where opts can specify a target channel

#### GAP 6: Memory Entry FK Integrity (MEDIUM)

**Problem**: `MemorySaveWorker` and `TurnClassifier` pass the ephemeral string conversation_id as `source_conversation_id` to `Store.create_memory_entry/1`. The `memory_entries.source_conversation_id` column has a FK to `conversations.id` (binary_id). The ephemeral string is not a valid UUID, so either:
- The insert fails and `source_conversation_id` is set to nil
- The FK constraint prevents insertion entirely

**What's needed**: Once conversations are DB-backed (Gap 3), this resolves automatically — the UUID will be valid.

---

## 3. Key Architectural Decisions Needed

### Decision 1: User Identity Model

**Question**: How should cross-channel user linking work?

| Option | Description | Pros | Cons |
|--------|-------------|------|------|
| A. `user_identities` join table | New table: `(user_id, channel, external_id, space_id, active)` | Clean separation; `users` stays simple; easy to add/remove channels | Migration + new module; need to decide when linking happens |
| B. Keep `users` as-is, auto-create per channel | Each channel gets its own user row; linking is manual/admin | Simplest initial change; backwards compatible | Same person = multiple users until manually linked; violates "one conversation" goal |
| C. `settings_users` as identity hub | settings_user links to a single `users` row; channel identities attach to settings_user | Leverages existing bridge; natural for web-dashboard users | Only works if user has a settings account; chat-only users have no hub |

**Recommendation for architect**: Option A (join table) provides the cleanest foundation. The `users` table becomes a logical identity, and `user_identities` maps platform-specific credentials. `settings_users.user_id` remains the bridge from the web dashboard.

### Decision 2: Conversation Scope — RESOLVED

**Resolved by user**: One perpetual conversation per user. Option A below is confirmed.

| Option | Description | Implication |
|--------|-------------|-------------|
| **A. One conversation per user, ever** | **SELECTED** — All messages across all time go into one conversation | Compaction essential; simplest lookup; Engine keyed by user_id |
| ~~B. One ACTIVE conversation per user~~ | ~~Close after idle timeout; new conversation on resume~~ | ~~Rejected by user~~ |
| ~~C. One conversation per user per "session"~~ | ~~New conversation when Engine starts fresh~~ | ~~Rejected by user~~ |

**Architect implications**:
- The Engine could register by **user_id** instead of conversation_id (1:1 mapping)
- `conversations.status` field is vestigial — always "active" — but may still be useful for sub-agent conversations (child records)
- `conversations.channel` needs rethinking — conversation spans all channels. Options: set to `"multi"`, store channel of first contact, or make nullable
- Compaction and context trimming are critical — a perpetual conversation will accumulate messages without bound. The existing `summary`/`summary_version`/`last_compacted_message_id` fields are well-suited for this
- `Store.get_or_create_conversation/2` can be simplified to a direct user_id lookup with a simple create-if-missing pattern

### Decision 3: Message Persistence Timing

**Question**: When should messages be written to the DB?

| Option | Description | Trade-off |
|--------|-------------|-----------|
| A. Synchronous (inline) | `Store.append_message` in Engine's `handle_call` before/after LLM call | Adds latency per message; full durability |
| B. Asynchronous (fire-and-forget) | Oban job or Task after turn completes | No latency impact; risk of message loss on crash |
| C. Batch at turn end | Persist all messages for the turn after response is generated | One DB write per turn; slight loss risk |

**Recommendation for architect**: Option C balances durability with performance. Persist the full turn (user message + assistant response + tool calls) as a batch after the Engine produces the response. This minimizes DB calls during the latency-sensitive LLM loop.

### Decision 4: Reply Routing Architecture

**Question**: Where does reply routing live?

| Option | Description |
|--------|-------------|
| A. In the Dispatcher | Dispatcher looks up user's channels and routes replies |
| B. New `ReplyRouter` module | Dedicated module that abstracts channel selection and delivery |
| C. In the Engine | Engine stores channel metadata and handles routing |

**Recommendation for architect**: Option B (dedicated ReplyRouter) provides the cleanest separation. The Engine produces a response; the Router decides where to deliver it. This also supports proactive messaging (no incoming message to derive routing from).

---

## 4. Files That Would Need to Change

### Core Changes (Must Change)

| File | What Changes | Why |
|------|-------------|-----|
| `lib/assistant/channels/dispatcher.ex` | Add user resolution + DB conversation lookup before Engine start; replace `derive_conversation_id` | Foundation for everything |
| `lib/assistant/orchestrator/engine.ex` | Accept DB UUID as conversation_id; persist messages; change `via_tuple` | Engine must use real IDs |
| `lib/assistant/schemas/user.ex` | Possibly restructure if adopting identity table model | Cross-channel identity |
| `lib/assistant/memory/store.ex` | Ensure `get_or_create_conversation` is called; add batch message persistence | Connect to Engine |

### New Files Needed

| File | Purpose |
|------|---------|
| `lib/assistant/channels/user_resolver.ex` (or similar) | Resolve platform user_id → DB user UUID; create if needed |
| `lib/assistant/channels/reply_router.ex` (or similar) | Route replies to the correct channel/adapter |
| `lib/assistant/schemas/user_identity.ex` (if Decision 1 = A) | Join table for multi-channel user linking |
| Migration for `user_identities` table | DB schema for channel identity mapping |

### Downstream Impacts (Cascade Changes)

| File | Impact |
|------|--------|
| `lib/assistant/memory/context_builder.ex` | Will work correctly once conversation_id is a valid UUID |
| `lib/assistant/memory/turn_classifier.ex` | conversation_id will be a valid UUID — memory agent lookups will work |
| `lib/assistant/scheduler/workers/memory_save_worker.ex` | source_conversation_id will be a valid FK |
| `lib/assistant/orchestrator/sub_agent.ex` | parent_conversation_id will be a valid UUID |
| `lib/assistant/orchestrator/context.ex` | `auto_build_context` will find real conversations for summary retrieval |
| All channel adapters (`telegram.ex`, `slack.ex`, etc.) | No changes to normalize/send_reply — these are correct as-is |
| Channel controllers | No changes — they delegate to Dispatcher |

### Testing Impact

| Area | Notes |
|------|-------|
| Existing Engine tests | Will need updated conversation_id format (UUID instead of string) |
| Dispatcher tests | New user resolution + conversation creation logic |
| Memory system tests | Will start working correctly (valid FKs) |
| New tests needed | User resolution, cross-channel linking, reply routing |

---

## 5. Existing Infrastructure That Supports This

The following already exists and can be leveraged:

1. **`Store.get_or_create_conversation/2`** — finds active conversation for user or creates new one. Currently dead code but exactly what's needed.
2. **`Conversation` schema** — has `user_id`, `channel`, `status`, `summary`, `parent_conversation_id`, `agent_type` fields. All needed.
3. **`Message` schema** — has `conversation_id`, `role`, `content`, `tool_calls`, `tool_results`. Ready for persistence.
4. **`User` schema** — has `external_id`, `channel`, unique constraint. Foundation for identity resolution.
5. **`settings_users.user_id` bridge** — already links web dashboard users to chat users. The identity model can build on this.
6. **`Channels.Registry`** — maps channel atoms to adapter modules. Can be used by ReplyRouter to look up the correct adapter.
7. **`Channels.Adapter.send_reply/3`** — uniform interface for sending to any channel. ReplyRouter can call this.
8. **PubSub `memory:turn_completed`** — already broadcasts conversation_id and user_id. Once these are real UUIDs, downstream memory systems work.

---

## 6. Risk Assessment

| Risk | Probability | Impact | Mitigation |
|------|-------------|--------|------------|
| Engine conversation_id format change breaks existing running conversations | Medium | Low (conversations are ephemeral anyway) | Deploy during low-traffic window; no persistent state to migrate |
| User resolution adds latency to every message | Medium | Medium | Cache user lookups (ETS or process dictionary); DB lookup is one indexed query |
| Cross-channel linking creates duplicate users initially | High | Low | Design for gradual linking; don't block messages on linking |
| Memory entries with old ephemeral conversation_ids become orphaned | Low | Low | Old entries have `source_conversation_id = nil` already; no data loss |
| DB conversation table grows unbounded | Medium | Medium | Existing `status` field + compaction system handles this |

---

## 7. Self-Verification Checklist

- [x] All source files read and analyzed (dispatcher, engine, adapters, schemas, store, context builder, memory system)
- [x] Version numbers: N/A (internal architecture, not external dependencies)
- [x] Security implications: User identity resolution must validate platform IDs; no credential exposure
- [x] Alternative approaches presented with pros/cons (4 decision areas)
- [x] Documentation organized for navigation (numbered sections, tables, flow diagrams)
- [x] All technical terms defined in context
- [x] Recommendations backed by code evidence
