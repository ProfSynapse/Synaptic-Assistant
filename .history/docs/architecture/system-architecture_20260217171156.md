# System Architecture: Skills-First AI Assistant

> Revision 6 — Updated 2026-02-17:
> - Memory retrieval upgraded to hybrid search: PostgreSQL FTS (tsvector) + pgvector embeddings + structured filters.
> - Embeddings generated via OpenRouter embeddings API and stored in Postgres (`vector` extension).
> - Voice: OpenRouter (LLM + STT), ElevenLabs (TTS behind TTSClient behaviour).
> - Prior: no sandbox (in-process + temp dir + MuonTrap), MCP-inspired skill behaviours,
>   Quantum for cron scheduling, Cloak.Ecto for field encryption.

## Executive Summary

This document defines the architecture for a headless, skills-first AI assistant built in Elixir on the BEAM VM. The system receives user messages from multiple channels (Google Chat, Telegram, WhatsApp, Voice), routes them through an LLM brain (OpenRouter) that selects and executes modular skills organized by domain (email, calendar, CRM, files, tasks, memory). OpenRouter provides LLM chat completions with tool calling, speech-to-text (STT), and embedding generation. ElevenLabs provides text-to-speech (TTS) via a thin Req-based HTTP wrapper behind a `TTSClient` behaviour. Skills run in-process as supervised OTP tasks — no external sandbox needed. Data is stored in PostgreSQL with hybrid retrieval (FTS + pgvector + structured filters) for memory and knowledge recall. File content is managed through a synced Google Drive mirror with normalized representations (docs -> markdown, sheets -> csv, slides -> markdown + assets). The skill interface follows MCP-inspired patterns (self-describing tools with JSON schemas) for future ecosystem compatibility.

The architecture leverages OTP supervision trees for fault tolerance, GenServer processes for conversation isolation, Oban for persistent job queuing, and Quantum for cron scheduling — all backed by PostgreSQL. The BEAM VM's concurrency model makes it uniquely suited for an agent orchestration system that must manage multiple concurrent conversations, skill executions, and external API interactions with built-in circuit breaking and fault recovery.

---

## 1. System Context (C4 Level 1)

### External Actors

| Actor | Type | Interaction |
|-------|------|-------------|
| Users | Human | Send/receive messages via channels |
| Google Chat | Channel | Webhook-based messaging |
| Telegram | Channel | Bot API (long-polling or webhook) |
| WhatsApp | Channel | WhatsApp Business API webhooks |
| Voice | Channel | STT input (OpenRouter) + TTS output (ElevenLabs) |
| OpenRouter | AI Provider | Chat completions with tool calling, STT, embeddings |
| ElevenLabs | AI Provider | Text-to-speech (TTS) via HTTP API |
| Google Drive | Integration | File storage, versioning, archive |
| Gmail | Integration | Email sending/reading |
| Google Calendar | Integration | Event management |
| Google Docs/Sheets | Integration | Document manipulation |
| HubSpot CRM | Integration | Contact, deal, company management |
| Obsidian Vault | Integration | Markdown knowledge base (accessed via Google Drive) |
| Google Chat Webhook | Alerting | Error/operational notifications |
| Email (SMTP) | Alerting | Error notification delivery |

### System Boundary

```
Users
  |
  v
[Google Chat] [Telegram] [WhatsApp] [Voice]
  |              |           |          |
  +------+-------+-----+-----+----+----+
         |             |          |
         v             v          v
    +------------------------------------+
    |     AI Assistant (Elixir/BEAM)     |
    |                                     |
    |  Message Gateway -> Orchestrator    |
    |  -> Skill Executor (in-process)     |
    +------------------------------------+
         |        |         |         |
         v        v         v         v
    [OpenRouter] [Google] [HubSpot] [ElevenLabs]
    [LLM+STT]   [Suite]             [TTS]
```

---

## 2. Container Architecture (C4 Level 2)

The system is a single Elixir application (OTP release) with clearly separated internal domains. It is NOT a microservices architecture — it is a modular monolith leveraging OTP's process isolation for the benefits of service boundaries without the overhead of network calls.

### Containers

#### A. Message Gateway

**Purpose**: Receive messages from all channels, normalize to common format, route responses back.

**Implementation**: Phoenix endpoint for webhooks + channel-specific adapter modules implementing a shared `ChannelAdapter` behaviour.

**Responsibilities**:
- Accept inbound webhooks (Google Chat, Telegram, WhatsApp)
- Normalize messages to `ConversationMessage` struct
- Route outbound responses to correct channel adapter
- Handle channel-specific formatting (markdown, cards, buttons)
- Manage voice I/O (OpenRouter STT -> text -> process -> ElevenLabs TTS -> audio)

**Key modules**:
- `Assistant.Channels.Adapter` — ChannelAdapter behaviour (compile-time contract)
- `Assistant.Channels.GoogleChat` — Google Chat adapter (GenServer)
- `Assistant.Channels.Telegram` — Telegram Bot API adapter (GenServer)
- `Assistant.Channels.WhatsApp` — WhatsApp Business API adapter (GenServer)
- `Assistant.Channels.Voice` — Voice I/O bridge: OpenRouter STT + ElevenLabs TTS (GenServer)
- `Assistant.Channels.Message` — ConversationMessage struct

#### B. Orchestration Engine

**Purpose**: The "brain" — manages conversation state, coordinates LLM calls, and executes the agent loop.

**Implementation**: GenServer per active conversation, managed by DynamicSupervisor.

**Responsibilities**:
- Maintain conversation state (message history, active skill context)
- Call OpenRouter with conversation context + available tool definitions
- Execute the agent loop (LLM response -> tool call -> skill execution -> feed result back)
- Enforce iteration limits and circuit breakers
- Track token usage and cost

**Key modules**:
- `Assistant.Orchestrator.Engine` — GenServer per conversation (the main orchestration loop)
- `Assistant.Orchestrator.LLMClient` — OpenRouter client (behind behaviour for testability)
- `Assistant.Orchestrator.Context` — Context assembly for LLM calls
- `Assistant.Orchestrator.Limits` — Iteration tracking and enforcement

#### C. Skill Registry & Executor

**Purpose**: Catalog of available skills and execution dispatch.

**Implementation**: ETS-backed registry with module discovery + Task.Supervisor for execution.

**Responsibilities**:
- Register/discover available skills with their OpenRouter tool schemas
- Validate tool call parameters against skill schemas
- Dispatch skill execution as supervised async tasks (in-process)
- Collect and format skill results for the agent loop

**Key modules**:
- `Assistant.Skills.Skill` — Skill behaviour definition (MCP-inspired)
- `Assistant.Skills.Registry` — ETS-backed skill catalog with module discovery
- `Assistant.Skills.Executor` — Task.Supervisor-based execution with timeouts
- `Assistant.Skills.Context` — SkillContext struct (injected dependencies)
- `Assistant.Skills.Result` — SkillResult struct

#### D. Content Sync Manager

**Purpose**: Maintain a synced content view of Google Drive and enforce non-destructive versioning.

**Implementation**: Service layer coordinating Drive API calls, normalized local representations, and database audit trail. File manipulation uses temp directories managed by Briefly.

**Responsibilities**:
- Bidirectional sync between Drive and local normalized content store
- Normalize Drive-native formats for manipulation and retrieval:
  - Google Docs -> Markdown
  - Google Sheets -> CSV
  - Google Slides -> Markdown + assets (per-slide content + media)
- Archive old versions (move to archive folder on Drive, never delete)
- Publish normalized edits back to Drive-native formats
- Maintain full audit trail in database
- Handle failure recovery (restore from archive if upload fails)

**Key modules**:
- `Assistant.Files.SyncManager` — Orchestrates sync/normalize/publish/archive workflow
- `Assistant.Files.Normalizer` — Format conversion (docs->md, sheets->csv, slides->md+assets)
- `Assistant.Files.Workspace` — Temp directory management via Briefly
- `Assistant.Files.Version` — FileVersion Ecto schema

#### E. Integration Layer

**Purpose**: Clients for all external services.

**Implementation**: Service modules using Req for HTTP, Goth for Google OAuth. Each integration is behind a behaviour for Mox testability.

**Key modules**:
- `Assistant.Integrations.Google.Auth` — OAuth2 via Goth (service account with domain-wide delegation)
- `Assistant.Integrations.Google.Drive` — Google Drive API client
- `Assistant.Integrations.Google.Gmail` — Gmail API client
- `Assistant.Integrations.Google.Calendar` — Calendar API client
- `Assistant.Integrations.HubSpot` — Custom HubSpot API client (contacts, deals, companies, notes)
- `Assistant.Integrations.OpenRouter` — LLM (chat completions + tool calling) and STT (speech-to-text)
- `Assistant.Integrations.ElevenLabs` — TTS (text-to-speech) via Req HTTP wrapper, behind `TTSClient` behaviour

#### F. Notification & Alerting Service

**Purpose**: Route errors and operational events to Google Chat and email.

**Implementation**: GenServer for routing + Oban workers for async dispatch.

**Responsibilities**:
- Receive structured error events from any component
- Classify by severity (info, warning, error, critical)
- Dispatch to Google Chat webhook (immediate for error+)
- Dispatch to email via Swoosh (batched or immediate based on severity)
- Rate limit notifications to prevent flooding
- Deduplicate repeated errors within a time window

**Key modules**:
- `Assistant.Notifications.Router` — Severity routing + dedup GenServer
- `Assistant.Notifications.GoogleChat` — Google Chat webhook sender (Oban worker)
- `Assistant.Notifications.Email` — Email sender via Swoosh (Oban worker)

#### G. Scheduler

**Purpose**: Execute recurring tasks (cron-style) and reliable async jobs.

**Implementation**: Quantum for time-based cron triggers + Oban for reliable job execution with retries.

**Responsibilities**:
- Define recurring skill executions on schedules
- Trigger conversations/skill executions at scheduled times
- Handle missed executions (catch-up policy)
- Persistent job queue for async work

**Key modules**:
- `Assistant.Scheduler.Cron` — Quantum scheduler configuration
- `Assistant.Scheduler.Jobs` — Oban job definitions

#### H. Resilience

**Purpose**: Circuit breakers and rate limiting for fault tolerance.

**Implementation**: GenServer per skill for circuit breaker state + rate limiter module.

**Key modules**:
- `Assistant.Resilience.CircuitBreaker` — Per-skill circuit breaker GenServer with DB persistence for crash recovery
- `Assistant.Resilience.RateLimiter` — Global + per-user rate limiting

#### I. Memory & Persistence

**Purpose**: Store conversation history, long-term memory, and operational data.

**Implementation**: PostgreSQL via Ecto with hybrid retrieval: full-text search (tsvector/tsquery), pgvector similarity search, and structured filters.

**Responsibilities**:
- Persist conversation messages and metadata
- Store long-term memories with tags, categories, text index, and embeddings
- Track skill execution history and audit trail
- Store file version records
- Manage user/channel configuration

**Key modules**:
- `Assistant.Memory.Store` — Conversation persistence
- `Assistant.Memory.Search` — Hybrid retrieval (FTS + pgvector + structured filter queries)
- `Assistant.Memory.ContextBuilder` — Assemble context for LLM calls (hybrid-ranked retrieval weighted by importance)
- `Assistant.Memory.Entry` — MemoryEntry Ecto schema

---

## 3. Component Architecture (C4 Level 3)

### 3.1 Orchestration Engine — Internal Components

```
ConversationSupervisor (DynamicSupervisor)
|
+-- Engine (GenServer, per conversation)
|   +-- State: conversation_id, channel, user, message_history,
|   |         turn_counter, skill_call_count, circuit_breaker_state
|   |
|   +-- handle_cast(:new_message, message)
|   |   +-- Triggers agent loop via Orchestrator.Engine
|   |
|   +-- handle_info(:agent_loop_timeout)
|   |   +-- Breaks loop, sends timeout response
|   |
|   +-- handle_info(:conversation_idle_timeout)
|       +-- Persists state, terminates GenServer
|
+-- Limits (pure module, no process)
|   +-- check_skill_timeout(skill_id, elapsed) -> :ok | :tripped
|   +-- check_turn_limit(turn_call_count, max) -> :ok | :tripped
|   +-- check_conversation_limit(conv_call_count, window, max) -> :ok | :tripped
|
+-- CircuitBreaker (GenServer, per skill)
    +-- Tracks failure count, state (closed/open/half-open)
    +-- Persists state to DB for crash recovery
    +-- on_trip(level, context) -> side effects (log, notify, respond)
```

### 3.2 Agent Loop Flow

```
User sends message
    |
    v
Engine (GenServer) receives message
    |
    v
Load conversation history from DB
    |
    v
Build messages array for OpenRouter
(system prompt + history + memory context + new message + available tools)
    |
    v
+--- AGENT LOOP START ---+
|                         |
|  Call OpenRouter API    |
|       |                 |
|       v                 |
|  Response type?         |
|   |           |         |
|   v           v         |
|  text      tool_call    |
|   |           |         |
|   v           v         |
|  DONE    Validate call  |
|           |             |
|           v             |
|     Check circuit       |
|     breakers + limits   |
|      |        |         |
|      v        v         |
|    OK      TRIPPED      |
|    |         |          |
|    v         v          |
|  Execute   Error resp   |
|  skill     + notify     |
|  (in-proc)   |          |
|    |         v          |
|    v        DONE        |
|  Feed result            |
|  back to LLM            |
|    |                    |
|    +-- loop ------------+
|                         |
+-------------------------+
    |
    v
Persist conversation to DB
    |
    v
Send response via channel adapter
```

### 3.3 Circuit Breaker Configuration

```elixir
# Default configuration (overridable per skill, per user, globally)
config :assistant, Assistant.Resilience.CircuitBreaker,
  # Tier 1: Per-skill execution timeout
  skill_timeout_ms: 30_000,          # 30 seconds max per skill

  # Tier 2: Per-turn tool call limit
  turn_max_tool_calls: 10,           # Max 10 tool calls per user message

  # Tier 3: Per-conversation sliding window
  conversation_max_tool_calls: 50,   # Max 50 tool calls
  conversation_window_ms: 300_000,   # Within 5 minute window

  # Global circuit breaker
  global_failure_threshold: 5,       # 5 consecutive failures
  global_recovery_timeout_ms: 60_000 # 1 minute before half-open
```

### 3.4 Skill Behaviour (MCP-Inspired)

Skills are self-describing Elixir modules implementing the `Assistant.Skills.Skill` behaviour. This provides compile-time contract enforcement and is compatible with OpenRouter's tool-calling format.

```elixir
defmodule Assistant.Skills.Skill do
  @doc "Return tool definition for OpenRouter (MCP-compatible JSON schema)"
  @callback tool_definition() :: %{
    name: String.t(),
    description: String.t(),
    parameters: map()  # JSON Schema
  }

  @doc "Execute the skill with validated parameters"
  @callback execute(params :: map(), context :: Assistant.Skills.Context.t()) ::
    {:ok, Assistant.Skills.Result.t()} | {:error, term()}

  @doc "Domain this skill belongs to"
  @callback domain() :: atom()

  @doc "Isolation level needed (future-proofing for sandbox)"
  @callback isolation_level() :: :none | :temp_workspace | :container | :sandbox
end
```

**Example skill implementation**:

```elixir
defmodule Assistant.Skills.Files.Write do
  @behaviour Assistant.Skills.Skill

  @impl true
  def tool_definition do
    %{
      name: "files.write",
      description: "Write or update managed content in the synced store and publish back to Drive safely.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "file_ref" => %{"type" => "string", "description" => "Managed file reference"},
          "instructions" => %{"type" => "string", "description" => "What modifications to make"}
        },
        "required" => ["file_ref", "instructions"]
      }
    }
  end

  @impl true
  def domain, do: :files

  @impl true
  def isolation_level, do: :temp_workspace

  @impl true
  def execute(params, context) do
    # Uses SyncManager for safe sync/normalize/publish/archive
    # Uses Briefly for temp workspace management
    # Returns {:ok, %SkillResult{}} or {:error, reason}
  end
end
```

**Task skill reference convention**: Task skills use compact CLI references (`task_ref`, e.g., `t_9X4K2M7`) instead of UUIDs in command arguments/results to reduce token usage. UUID remains internal-only at the persistence layer. Canonical format and error semantics are defined in `task-management-design.md` Section 2.3 (TaskRef Specification).

### 3.5 Skill Execution Model

Skills execute in-process as supervised async tasks. No external sandbox is needed because skills are pre-built Elixir modules, not arbitrary code.

**Execution tiers by isolation level**:

| Isolation Level | How It Executes | Use Case |
|-----------------|-----------------|----------|
| `:none` | Direct function call in supervised Task | API-calling skills (email, calendar, CRM, messaging) |
| `:temp_workspace` | Function call with Briefly temp directory | File/content manipulation (synced Drive mirror, document conversion) |
| `:container` | MuonTrap with cgroup limits | CLI tools (pandoc, ffmpeg) — OS process isolation |
| `:sandbox` | Deferred (E2B or similar) | Future: user-authored custom skills |

**MuonTrap for CLI tool isolation**:

```elixir
# Execute CLI tools with resource limits
MuonTrap.cmd("pandoc", [input_path, "-o", output_path],
  cgroup_controllers: ["memory", "cpu"],
  cgroup_path: "assistant/skills",
  cgroup_sets: [
    {"memory", "memory.limit_in_bytes", "#{256 * 1024 * 1024}"},  # 256MB
    {"cpu", "cpu.cfs_quota_us", "50000"}  # 50% CPU
  ],
  timeout: 30_000  # 30 second timeout
)
```

### 3.6 Skill Domain Organization

```
Assistant.Skills
+-- Email
|   +-- Send
|   +-- Read
|   +-- Search
+-- Calendar
|   +-- CreateEvent
|   +-- ListEvents
|   +-- UpdateEvent
+-- Files
|   +-- Read
|   +-- Write (uses SyncManager)
|   +-- Search
|   +-- Move
|   +-- Sync
+-- HubSpot
|   +-- Contacts
|   +-- Deals
|   +-- Notes
+-- Tasks
|   +-- Create
|   +-- Update
|   +-- List
```

---

## 4. Data Architecture

### 4.1 Entity Relationship Diagram

```
+---------------+     +------------------+     +------------------+
|    users      |     |  conversations   |     |    messages       |
+---------------+     +------------------+     +------------------+
| id (PK)       |--+  | id (PK)          |--+  | id (PK)          |
| external_id   |  +->| user_id (FK)     |  +->| conversation_id  |
| channel       |     | channel          |     | role             |
| display_name  |     | started_at       |     | content          |
| preferences   |     | last_active_at   |     | tool_calls       |
| created_at    |     | status           |     | tool_results     |
| updated_at    |     | metadata         |     | token_count      |
+---------------+     +------------------+     | created_at       |
                                               +------------------+

+-------------------+     +----------------------+
| skill_executions  |     |    file_versions     |
+-------------------+     +----------------------+
| id (PK)           |     | id (PK)              |
| conversation_id   |     | skill_execution_id   |
| skill_id          |     | drive_file_id        |
| parameters        |     | drive_file_name      |
| result            |     | drive_folder_id      |
| status            |     | version_number       |
| error_message     |     | archive_file_id      |
| duration_ms       |     | archive_folder_id    |
| started_at        |     | checksum_before      |
| completed_at      |     | checksum_after       |
+-------------------+     | operation            |
                          | created_at           |
                          +----------------------+

+-------------------+     +----------------------+
| file_operation_log|     |  scheduled_tasks     |
+-------------------+     +----------------------+
| id (PK)           |     | id (PK)              |
| file_version_id   |     | user_id (FK)         |
| step              |     | skill_id             |
| status            |     | parameters           |
| details           |     | cron_expression      |
| created_at        |     | channel              |
+-------------------+     | enabled              |
                          | last_run_at          |
                          | next_run_at          |
                          | created_at           |
                          +----------------------+

+------------------+     +----------------------+
|    memories      |     |  notification_log    |
+------------------+     +----------------------+
| id (PK)          |     | id (PK)              |
| user_id (FK)     |     | severity             |
| content          |     | component            |
| tags (text[])    |     | error_code           |
| category         |     | message              |
| source_type      |     | context (jsonb)      |
| source_conv_id   |     | dispatched_to        |
| importance       |     | dispatched_at        |
| search_vector    |     | acknowledged_at      |
| created_at       |     | created_at           |
| accessed_at      |     +----------------------+
| decay_factor     |
+------------------+

+------------------------+     +------------------------+
| skill_configs          |     | notification_channels  |
+------------------------+     +------------------------+
| id (PK)                |     | id (PK)                |
| skill_id               |     | name                   |
| enabled                |     | type                   |
| config (jsonb)         |     | config (jsonb, encrypted)|
| created_at             |     | enabled                |
| updated_at             |     | created_at             |
+------------------------+     +------------------------+

+------------------------+
| notification_rules     |
+------------------------+
| id (PK)                |
| channel_id (FK)        |
| severity_min           |
| component_filter       |
| enabled                |
| created_at             |
+------------------------+
```

### 4.2 Database Schema Details

#### Users

```sql
CREATE TABLE users (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  external_id VARCHAR(255) NOT NULL,
  channel VARCHAR(50) NOT NULL,
  display_name VARCHAR(255),
  preferences JSONB DEFAULT '{}',
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE(external_id, channel)
);
```

#### Conversations

```sql
CREATE TABLE conversations (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES users(id),
  channel VARCHAR(50) NOT NULL,
  started_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  last_active_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  status VARCHAR(20) NOT NULL DEFAULT 'active',
  metadata JSONB DEFAULT '{}',
  CONSTRAINT valid_status CHECK (status IN ('active', 'idle', 'closed'))
);

CREATE INDEX idx_conversations_user_id ON conversations(user_id);
CREATE INDEX idx_conversations_status ON conversations(status);
CREATE INDEX idx_conversations_last_active ON conversations(last_active_at);
```

#### Messages

```sql
CREATE TABLE messages (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  conversation_id UUID NOT NULL REFERENCES conversations(id),
  role VARCHAR(20) NOT NULL,
  content TEXT,
  tool_calls JSONB,
  tool_results JSONB,
  token_count INTEGER,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT valid_role CHECK (role IN ('system', 'user', 'assistant', 'tool'))
);

CREATE INDEX idx_messages_conversation_id ON messages(conversation_id);
CREATE INDEX idx_messages_created_at ON messages(conversation_id, created_at);
```

#### Skill Executions

```sql
CREATE TABLE skill_executions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  conversation_id UUID NOT NULL REFERENCES conversations(id),
  skill_id VARCHAR(100) NOT NULL,
  parameters JSONB NOT NULL DEFAULT '{}',
  result JSONB,
  status VARCHAR(20) NOT NULL DEFAULT 'pending',
  error_message TEXT,
  duration_ms INTEGER,
  started_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  completed_at TIMESTAMPTZ,
  CONSTRAINT valid_exec_status CHECK (status IN ('pending', 'running', 'completed', 'failed', 'timeout'))
);

CREATE INDEX idx_skill_executions_conversation ON skill_executions(conversation_id);
CREATE INDEX idx_skill_executions_skill ON skill_executions(skill_id);
CREATE INDEX idx_skill_executions_status ON skill_executions(status);
```

#### File Versions

```sql
CREATE TABLE file_versions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  skill_execution_id UUID REFERENCES skill_executions(id),
  drive_file_id VARCHAR(255) NOT NULL,
  drive_file_name VARCHAR(500) NOT NULL,
  drive_folder_id VARCHAR(255),
  canonical_type VARCHAR(20) NOT NULL,   -- 'doc', 'sheet', 'slide', 'binary'
  normalized_format VARCHAR(20) NOT NULL, -- 'markdown', 'csv', 'markdown_assets', 'binary'
  version_number INTEGER NOT NULL DEFAULT 1,
  archive_file_id VARCHAR(255),
  archive_folder_id VARCHAR(255),
  checksum_before VARCHAR(64),
  checksum_after VARCHAR(64),
  operation VARCHAR(20) NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  sync_status VARCHAR(20) NOT NULL DEFAULT 'synced',
  CONSTRAINT valid_file_op CHECK (operation IN ('create', 'update', 'archive', 'restore'))
);

CREATE INDEX idx_file_versions_drive_file ON file_versions(drive_file_id);
CREATE INDEX idx_file_versions_execution ON file_versions(skill_execution_id);
CREATE INDEX idx_file_versions_sync_status ON file_versions(sync_status);
```

#### File Operation Log (Step-Level Audit)

```sql
CREATE TABLE file_operation_log (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  file_version_id UUID NOT NULL REFERENCES file_versions(id),
  step VARCHAR(20) NOT NULL,
  status VARCHAR(20) NOT NULL,
  details JSONB DEFAULT '{}',
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT valid_step CHECK (step IN ('pull', 'manipulate', 'archive', 'verify', 'replace', 'record')),
  CONSTRAINT valid_step_status CHECK (status IN ('started', 'completed', 'failed'))
);

CREATE INDEX idx_file_op_log_version ON file_operation_log(file_version_id);
```

#### Memories (Hybrid: FTS + pgvector + Structured Filters)

```sql
CREATE TABLE memories (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID REFERENCES users(id),
  content TEXT NOT NULL,
  tags TEXT[] DEFAULT '{}',
  category VARCHAR(50),
  source_type VARCHAR(30),  -- 'conversation', 'skill_execution', 'user_explicit', 'system'
  source_conversation_id UUID REFERENCES conversations(id),
  importance DECIMAL(3, 2) DEFAULT 0.5,
  embedding vector(1536),
  embedding_model VARCHAR(120),
  search_vector tsvector GENERATED ALWAYS AS (
    to_tsvector('english', coalesce(content, ''))
  ) STORED,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  accessed_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  decay_factor DECIMAL(3, 2) DEFAULT 1.0,
  CONSTRAINT valid_source_type CHECK (
    source_type IN ('conversation', 'skill_execution', 'user_explicit', 'system')
  )
);

CREATE INDEX idx_memories_user ON memories(user_id);
CREATE INDEX idx_memories_search ON memories USING gin(search_vector);
CREATE INDEX idx_memories_embedding ON memories USING hnsw (embedding vector_cosine_ops);
CREATE INDEX idx_memories_tags ON memories USING gin(tags);
CREATE INDEX idx_memories_category ON memories(category);
CREATE INDEX idx_memories_importance ON memories(importance DESC);
CREATE INDEX idx_memories_created ON memories(created_at DESC);
CREATE INDEX idx_memories_source_type ON memories(source_type);
```

**Memory retrieval pattern** (hybrid ranking with Reciprocal Rank Fusion):
```sql
WITH fts AS (
  SELECT id,
         row_number() OVER (ORDER BY ts_rank(search_vector, plainto_tsquery('english', $1)) DESC) AS fts_rank_pos
  FROM memories
  WHERE user_id = $2
    AND search_vector @@ plainto_tsquery('english', $1)
    AND ($3::text[] IS NULL OR tags && $3)
    AND ($4::varchar IS NULL OR category = $4)
),
vec AS (
  SELECT id,
         row_number() OVER (ORDER BY embedding <=> $5) AS vec_rank_pos
  FROM memories
  WHERE user_id = $2
    AND embedding IS NOT NULL
    AND ($3::text[] IS NULL OR tags && $3)
    AND ($4::varchar IS NULL OR category = $4)
)
SELECT m.id, m.content, m.tags, m.category, m.importance,
       (1.0 / (60 + COALESCE(fts.fts_rank_pos, 10_000))) +
       (1.0 / (60 + COALESCE(vec.vec_rank_pos, 10_000))) AS hybrid_score
FROM memories m
LEFT JOIN fts ON fts.id = m.id
LEFT JOIN vec ON vec.id = m.id
WHERE m.user_id = $2
ORDER BY hybrid_score * m.importance DESC
LIMIT $6;
```

**Embedding pipeline**: At memory write time (or async backfill), generate embeddings through OpenRouter and persist vectors in `memories.embedding`. Oban workers handle retries/backfill, and the context builder uses hybrid ranking by default.

#### Scheduled Tasks

```sql
CREATE TABLE scheduled_tasks (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES users(id),
  skill_id VARCHAR(100) NOT NULL,
  parameters JSONB NOT NULL DEFAULT '{}',
  cron_expression VARCHAR(100) NOT NULL,
  channel VARCHAR(50) NOT NULL,
  enabled BOOLEAN NOT NULL DEFAULT true,
  last_run_at TIMESTAMPTZ,
  next_run_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_scheduled_tasks_next_run ON scheduled_tasks(next_run_at) WHERE enabled = true;
```

#### Skill Configs

```sql
CREATE TABLE skill_configs (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  skill_id VARCHAR(100) NOT NULL UNIQUE,
  enabled BOOLEAN NOT NULL DEFAULT true,
  config JSONB DEFAULT '{}',
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
```

#### Notification Channels and Rules

```sql
CREATE TABLE notification_channels (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name VARCHAR(100) NOT NULL,
  type VARCHAR(50) NOT NULL,
  config BYTEA NOT NULL,  -- Encrypted via Cloak.Ecto (webhook URLs, email addresses)
  enabled BOOLEAN NOT NULL DEFAULT true,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT valid_channel_type CHECK (type IN ('google_chat_webhook', 'email', 'telegram'))
);

CREATE TABLE notification_rules (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  channel_id UUID NOT NULL REFERENCES notification_channels(id),
  severity_min VARCHAR(20) NOT NULL DEFAULT 'error',
  component_filter VARCHAR(100),
  enabled BOOLEAN NOT NULL DEFAULT true,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT valid_rule_severity CHECK (severity_min IN ('info', 'warning', 'error', 'critical'))
);

CREATE TABLE notification_log (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  severity VARCHAR(20) NOT NULL,
  component VARCHAR(100) NOT NULL,
  error_code VARCHAR(100),
  message TEXT NOT NULL,
  context JSONB DEFAULT '{}',
  dispatched_to VARCHAR(50)[] DEFAULT '{}',
  dispatched_at TIMESTAMPTZ,
  acknowledged_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT valid_severity CHECK (severity IN ('info', 'warning', 'error', 'critical'))
);

CREATE INDEX idx_notification_log_severity ON notification_log(severity);
CREATE INDEX idx_notification_log_created ON notification_log(created_at);
```

---

## 5. API Specifications

### 5.1 Webhook Endpoints (Phoenix Router)

```elixir
# router.ex
scope "/webhooks", AssistantWeb do
  post "/google-chat",   GoogleChatController, :handle
  post "/telegram",      TelegramController, :handle
  post "/whatsapp",      WhatsAppController, :handle
  post "/voice/inbound", VoiceController, :handle_inbound
end

# Health & operational endpoints
scope "/api", AssistantWeb do
  get "/health", HealthController, :check
  get "/health/deep", HealthController, :deep_check
end
```

### 5.2 Normalized Message Format

```elixir
defmodule Assistant.Channels.Message do
  @type t :: %__MODULE__{
    id: String.t(),
    channel: :google_chat | :telegram | :whatsapp | :voice,
    channel_message_id: String.t(),
    user_id: String.t(),
    content: String.t(),
    attachments: [attachment()],
    metadata: map(),
    timestamp: DateTime.t()
  }

  @type attachment :: %{
    type: :file | :image | :audio,
    url: String.t(),
    mime_type: String.t(),
    file_name: String.t() | nil
  }
end
```

### 5.3 Skill Execution Context

```elixir
defmodule Assistant.Skills.Context do
  @type t :: %__MODULE__{
    conversation_id: String.t(),
    user_id: String.t(),
    workspace_path: String.t() | nil,  # temp dir path (for :temp_workspace skills)
    integrations: integrations(),
    file_manager: module(),
    logger: module()
  }

  @type integrations :: %{
    drive: module() | nil,
    gmail: module() | nil,
    calendar: module() | nil,
    hubspot: module() | nil
  }
end
```

### 5.4 Skill Result Format

```elixir
defmodule Assistant.Skills.Result do
  @type t :: %__MODULE__{
    status: :ok | :error,
    content: String.t(),
    files_produced: [%{path: String.t(), name: String.t(), mime_type: String.t()}],
    side_effects: [atom()],  # [:file_updated, :email_sent, :event_created]
    metadata: map()
  }
end
```

---

## 6. Technology Decisions

### ADR-001: Elixir on BEAM VM

**Status**: Accepted

**Context**: Need a runtime for a concurrent, fault-tolerant agent orchestration system handling multiple channels, conversations, and skill executions simultaneously.

**Decision**: Elixir 1.17+ on OTP 27+

**Rationale**:
- GenServer per conversation provides natural state isolation
- Supervisor trees provide automatic fault recovery (crashed skill = restart, not system down)
- Lightweight processes handle 10,000+ concurrent conversations
- Built-in timeout handling eliminates external circuit breaker libraries
- Ecto provides best-in-class database interaction
- Behaviours enforce interface contracts at compile time

**Trade-offs**:
- No active HubSpot library — custom HTTP client needed (subset only)
- No ElevenLabs library — thin Req HTTP wrapper needed (small surface area: synthesize, stream, list voices)
- Smaller AI/LLM ecosystem than TypeScript/Python (but sufficient — LangChain Elixir, ExLLM, ReqLLM exist)

### ADR-002: No Sandbox (In-Process Skill Execution)

**Status**: Accepted

**Context**: Skills are pre-built API wrappers and file manipulation modules, not arbitrary code execution. Most skills make API calls (email, calendar, CRM, messaging). File skills manipulate files in temp directories.

**Decision**: Skills run in-process as supervised OTP tasks. Temp directories (via Briefly) for file manipulation. MuonTrap with cgroup limits for CLI tools (pandoc, ffmpeg). No external sandbox.

**Rationale**:
- Eliminates E2B dependency, cost, cold start latency, and custom HTTP client
- 90%+ of skills are API calls that need zero isolation
- File manipulation needs directory scoping, not VM isolation
- MuonTrap provides sufficient OS-level isolation for CLI tools
- Reduces attack surface (no credential injection into sandboxes)

**Trade-offs**:
- No path to user-authored arbitrary code execution without adding sandbox later
- CLI tools (via MuonTrap) have weaker isolation than full VM sandbox

**Future extensibility**: The `isolation_level` callback in the Skill behaviour supports `:container` and `:sandbox` tiers. Adding E2B or similar later is an additive change to the Executor, not a rearchitecture.

### ADR-003: PostgreSQL as Single Data Store

**Status**: Accepted

**Context**: Need persistent storage for conversations, files, memories, jobs, and notifications.

**Decision**: PostgreSQL for all storage needs with hybrid memory retrieval: FTS (tsvector/tsquery) + pgvector similarity + structured filters.

**Rationale**:
- Ecto has excellent PostgreSQL support
- Oban uses PostgreSQL for job queuing (no Redis needed)
- Built-in full-text search and pgvector both run in PostgreSQL (single operational datastore)
- Tags (TEXT[] with GIN index) provide explicit categorization and fast array overlap queries
- JSONB columns handle flexible/schema-less data
- Single database simplifies operations and deployment
- Railway provides managed PostgreSQL
- pgvector-elixir supports Ecto/Postgrex cleanly (vector type, cosine distance, HNSW/IVFFlat indexes)

### ADR-004: Quantum + Oban for Scheduling and Jobs

**Status**: Accepted

**Context**: Need time-based cron scheduling and reliable async job processing.

**Decision**: Quantum for cron triggers, Oban (PostgreSQL-backed) for reliable job execution.

**Rationale**:
- Quantum handles time-based scheduling natively in BEAM
- Oban provides persistent job queue with retries, uniqueness, and backoff
- Both use PostgreSQL (no Redis needed)
- Oban.Web dashboard available for monitoring

### ADR-005: Voice Architecture — OpenRouter STT + ElevenLabs TTS

**Status**: Accepted

**Context**: Need LLM (chat completions + tool calling), STT (speech-to-text), and TTS (text-to-speech) capabilities. OpenRouter provides reliable LLM and STT via its audio-capable chat completions API. OpenRouter's TTS support is not yet reliably available, so ElevenLabs is used for TTS.

**Decision**: Two AI providers with clear responsibility boundaries:
- **OpenRouter**: LLM chat completions + tool calling, STT (audio input via chat completions API)
- **ElevenLabs**: TTS only (text-to-speech synthesis via HTTP API)

**Rationale**:
- OpenRouter STT is confirmed working via audio input to chat completions — natural fit since the same API call can transcribe and begin processing
- ElevenLabs has mature, reliable TTS with extensive voice options and streaming support
- Both clients are thin Req-based HTTP wrappers behind behaviours (`LLMClient`/`STTClient` for OpenRouter, `TTSClient` for ElevenLabs)
- Two API keys (OpenRouter + ElevenLabs) is manageable — no operational complexity compared to the three-provider alternative (separate STT, LLM, TTS)
- If OpenRouter TTS becomes reliable later, swap the `TTSClient` implementation without changing the voice channel adapter

**Client evaluation for LLM**: Evaluate LangChain for Elixir, ExLLM, and ReqLLM. Select based on: tool calling maturity, streaming support, OpenRouter compatibility, and error handling quality.

**Fallback**: Raw HTTP via Req works if no library meets needs. All voice capabilities are behind behaviours for testability and provider swapping.

**TTSClient behaviour interface** (planned for Phase 4):
```elixir
defmodule Assistant.Integrations.TTSClient do
  @callback synthesize(text :: String.t(), opts :: keyword()) ::
    {:ok, audio_binary :: binary()} | {:error, term()}
  @callback stream(text :: String.t(), opts :: keyword()) ::
    {:ok, Enumerable.t()} | {:error, term()}
  @callback voices() :: {:ok, [map()]} | {:error, term()}
end
```

### ADR-006: Non-Destructive Synced Content Operations

**Status**: Accepted (non-negotiable requirement)

**Context**: User content must stay synced with Drive while remaining safe to manipulate locally. Every modification must preserve the original.

**Decision**: Sync-normalize-manipulate-publish with archive-before-replace and full audit trail.

**Workflow**:
1. **SYNC**: Pull latest Drive file into temp workspace, record checksum and metadata
2. **NORMALIZE**: Convert into canonical local form
  - Docs -> Markdown
  - Sheets -> CSV
  - Slides -> Markdown + assets
3. **MANIPULATE**: Skill modifies normalized content in workspace
4. **ARCHIVE**: Move original on Drive to `Archive/{folder_name}/{filename}_{ISO_timestamp}`, record archive location
5. **PUBLISH**: Convert normalized content back to Drive-native form and upload to original location
6. **VERIFY**: Confirm publish succeeded, compare checksums
7. **RECORD**: Create `file_versions` entry + `file_operation_log` entries with complete audit trail

**Failure recovery**:
- Normalize fails: Abort — original untouched, notify ops
- Archive fails: Abort — original untouched, notify ops
- Publish fails: Restore from archive (archive location is recorded), notify ops
- Each step logged to `file_operation_log` for idempotent recovery

### ADR-007: Cloak.Ecto for Field-Level Encryption

**Status**: Accepted

**Context**: Notification channel configs contain webhook URLs and email addresses that should not be stored in plaintext.

**Decision**: Use Cloak.Ecto for transparent field-level encryption in the database.

**Rationale**:
- Transparent encryption/decryption via Ecto types
- Encryption key managed via environment variable
- Protects sensitive config even if database is compromised

---

## 7. Security Architecture

### 7.1 Credential Management

| Credential | Storage | Access Pattern |
|------------|---------|----------------|
| OpenRouter API key | Railway env var | Loaded at boot via runtime.exs, never logged. Used for LLM + STT |
| ElevenLabs API key | Railway env var | Used by ElevenLabs TTS module only |
| Google service account JSON | Railway env var | Managed by Goth for token refresh |
| HubSpot API key | Railway env var | Used by HubSpot integration module only |
| Google Chat webhook URL | Railway env var | Used by notification worker only |
| Telegram bot token | Railway env var | Used by Telegram adapter only |
| WhatsApp API credentials | Railway env var | Used by WhatsApp adapter only |
| Database URL | Railway env var | Managed by Ecto |
| Cloak encryption key | Railway env var | Used by Cloak.Ecto for field encryption |
| Secret key base | Railway env var | Used by Phoenix for signing |

**Rule**: No credential ever enters application code, logs, or error messages.

### 7.2 In-Process Credential Safety

Since skills run in-process (no sandbox), credentials live in the same BEAM VM. This is safe because:
- Skills are pre-built modules, not arbitrary code — they cannot inspect other modules' state
- Integration clients are injected via the SkillContext — skills receive only the clients they need
- BEAM process isolation prevents GenServer state leakage between conversations
- No eval/code execution path exists (skills are compiled Elixir modules)
- MuonTrap-isolated CLI processes do NOT receive environment variables containing credentials

### 7.3 Input Validation

```
User message (raw)
    |
    v
Channel adapter sanitizes (strip control chars, enforce size limits)
    |
    v
Engine validates (content length, rate check)
    |
    v
OpenRouter receives validated input
    |
    v
Tool call response validated against skill JSON schema
    |
    v
Skill parameters validated by Executor before dispatch
```

Each boundary performs its own validation. No layer trusts upstream validation.

### 7.4 Prompt Injection Mitigation

- System prompt clearly delineates user input boundaries
- Tool call parameters are validated against JSON schemas before execution
- Skill descriptions are static (not user-influenced)
- Skills with destructive capabilities (file operations, email sending) require parameter validation
- All Drive file operations go through the versioning workflow (archive-before-modify)
- Webhook signature verification on all inbound channel messages

### 7.5 Rate Limiting

```elixir
config :assistant, Assistant.Resilience.RateLimiter,
  messages_per_minute: 20,
  messages_per_hour: 200,
  skill_executions_per_hour: 100,
  file_operations_per_hour: 50
```

Rate limiting is enforced at the Engine level before any LLM call.

---

## 8. OTP Supervision Tree

```
Assistant.Application (Application)
|
+-- Assistant.Repo (Ecto.Repo)
|
+-- AssistantWeb.Endpoint (Phoenix.Endpoint)
|   +-- Handles all HTTP/webhook traffic
|
+-- {Oban, oban_config()}
|   +-- Notification workers
|   +-- Scheduled task workers
|
+-- Assistant.Scheduler.Cron (Quantum)
|   +-- Time-based cron triggers
|
+-- Assistant.Orchestrator.ConversationSupervisor (DynamicSupervisor)
|   +-- Assistant.Orchestrator.Engine (GenServer, per conversation)
|       +-- Manages conversation state, agent loop, iteration limits
|
+-- Assistant.Skills.Executor.TaskSupervisor (Task.Supervisor)
|   +-- Supervised async tasks for skill execution
|
+-- Assistant.Skills.Registry (GenServer)
|   +-- ETS table of registered skill definitions
|
+-- Assistant.Resilience.CircuitBreaker.Supervisor (DynamicSupervisor)
|   +-- CircuitBreaker (GenServer, per skill) -- state persistence to DB
|
+-- Assistant.Channels.Telegram (GenServer, if using long-polling)
|   +-- Polls Telegram Bot API for updates
|
+-- Assistant.Integrations.Google.Auth (Goth)
|   +-- Manages Google OAuth2 token refresh
|
+-- Assistant.Notifications.Router (GenServer)
    +-- Severity routing + deduplication
```

### Restart Strategies

| Supervisor | Strategy | Rationale |
|------------|----------|-----------|
| Application | `:one_for_one` | Independent top-level services |
| ConversationSupervisor | `:one_for_one` | Conversations are independent |
| CircuitBreaker.Supervisor | `:one_for_one` | Circuit breakers are independent |

### Failure Scenarios and Recovery

| Failure | Supervisor Response | User Impact |
|---------|-------------------|-------------|
| Engine crash | Restart GenServer, reload state from DB | Brief delay, conversation resumes |
| Skill Task crash | Task.Supervisor captures exit, reports to Engine | Skill execution fails, user gets error message |
| MuonTrap CLI timeout | MuonTrap kills process, returns error | CLI skill fails gracefully |
| OpenRouter timeout | Engine handles, returns error to user | "I'm having trouble connecting" message |
| Database connection lost | Ecto pool handles reconnection | Brief service interruption |
| Phoenix endpoint crash | Supervisor restarts | Missed webhook (channel will retry) |
| Oban worker crash | Oban retries with backoff | Delayed notification |
| CircuitBreaker crash | Supervisor restarts, reloads state from DB | Brief gap in tracking (recovers) |

---

## 9. Deployment Architecture

### Railway Configuration

```
Railway Project
+-- Service: assistant (Elixir release, Dockerfile)
|   +-- PORT: 4000
|   +-- DATABASE_URL: (Railway PostgreSQL)
|   +-- SECRET_KEY_BASE: (generated)
|   +-- CLOAK_KEY: (generated, base64-encoded 32-byte key)
|   +-- OPENROUTER_API_KEY: (secret — LLM + STT)
|   +-- ELEVENLABS_API_KEY: (secret — TTS)
|   +-- GOOGLE_SERVICE_ACCOUNT_JSON: (secret)
|   +-- HUBSPOT_API_KEY: (secret)
|   +-- TELEGRAM_BOT_TOKEN: (secret)
|   +-- WHATSAPP_API_KEY: (secret)
|   +-- GOOGLE_CHAT_WEBHOOK_URL: (secret)
|   +-- NOTIFICATION_EMAIL_FROM: (config)
|   +-- OPENROUTER_MODEL: (config, default: anthropic/claude-sonnet-4-20250514)
|   +-- OPENROUTER_STT_MODEL: (config, default: openai/whisper-large-v3)
|   +-- ELEVENLABS_VOICE_ID: (config, default TBD — select during Phase 4)
|   +-- ELEVENLABS_MODEL_ID: (config, default: eleven_multilingual_v2)
|   +-- MIX_ENV: prod
|
+-- Database: PostgreSQL
```

### Dockerfile (Elixir Release)

```dockerfile
# Build stage
FROM hexpm/elixir:1.17.3-erlang-27.1-debian-bookworm-20240904 AS build

ENV MIX_ENV=prod

WORKDIR /app
COPY mix.exs mix.lock ./
RUN mix deps.get --only $MIX_ENV
RUN mix deps.compile

COPY config config
COPY lib lib
COPY priv priv
RUN mix compile
RUN mix release

# Runtime stage
FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y \
    libstdc++6 openssl libncurses5 locales \
    pandoc \
  && apt-get clean && rm -f /var/lib/apt/lists/*_*

ENV LANG=en_US.UTF-8
RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen

WORKDIR /app
COPY --from=build /app/_build/prod/rel/assistant ./

CMD ["bin/assistant", "start"]
```

Note: `pandoc` is installed in the runtime image for document conversion skills via MuonTrap.

---

## 10. Implementation Guidelines

### 10.1 Project Structure

```
assistant/
+-- config/
|   +-- config.exs              # Base configuration
|   +-- dev.exs                 # Dev environment
|   +-- prod.exs                # Production
|   +-- runtime.exs             # Runtime config (env vars)
|   +-- test.exs                # Test environment
|
+-- lib/
|   +-- assistant/
|   |   +-- application.ex      # OTP Application, supervision tree
|   |   +-- repo.ex             # Ecto Repo
|   |   |
|   |   +-- channels/           # Message Gateway
|   |   |   +-- adapter.ex      # ChannelAdapter behaviour
|   |   |   +-- telegram.ex     # Telegram adapter (GenServer)
|   |   |   +-- google_chat.ex  # Google Chat adapter
|   |   |   +-- whatsapp.ex     # WhatsApp adapter
|   |   |   +-- voice.ex        # Voice adapter (OpenRouter STT + ElevenLabs TTS)
|   |   |   +-- message.ex      # ConversationMessage struct
|   |   |
|   |   +-- orchestrator/       # Agent Loop
|   |   |   +-- engine.ex       # Main orchestration GenServer
|   |   |   +-- llm_client.ex   # OpenRouter client (behaviour)
|   |   |   +-- context.ex      # Context assembly for LLM calls
|   |   |   +-- limits.ex       # Iteration tracking + enforcement
|   |   |
|   |   +-- skills/             # Skill System
|   |   |   +-- skill.ex        # Skill behaviour definition
|   |   |   +-- registry.ex     # Skill discovery + ETS registry
|   |   |   +-- executor.ex     # Task.Supervisor-based execution
|   |   |   +-- result.ex       # SkillResult struct
|   |   |   +-- context.ex      # SkillContext (injected deps)
|   |   |   |
|   |   |   +-- email/          # Email domain skills
|   |   |   |   +-- send.ex
|   |   |   |   +-- read.ex
|   |   |   |   +-- search.ex
|   |   |   +-- calendar/       # Calendar domain skills
|   |   |   |   +-- create_event.ex
|   |   |   |   +-- list_events.ex
|   |   |   |   +-- update_event.ex
|   |   |   +-- drive/          # Google Drive domain skills
|   |   |   |   +-- read_file.ex
|   |   |   |   +-- update_file.ex
|   |   |   |   +-- list_files.ex
|   |   |   |   +-- search.ex
|   |   |   +-- markdown/       # Obsidian/Markdown domain skills
|   |   |   |   +-- edit.ex
|   |   |   |   +-- create.ex
|   |   |   |   +-- search.ex
|   |   |   |   +-- frontmatter.ex
|   |   |   +-- hubspot/        # HubSpot CRM domain skills
|   |   |   |   +-- contacts.ex
|   |   |   |   +-- deals.ex
|   |   |   |   +-- notes.ex
|   |   |   +-- tasks/          # Task management skills
|   |   |       +-- create.ex
|   |   |       +-- update.ex
|   |   |       +-- list.ex
|   |   |
|   |   +-- files/              # File Versioning System
|   |   |   +-- version_manager.ex  # PULL/ARCHIVE/REPLACE orchestration
|   |   |   +-- workspace.ex        # Temp directory management (Briefly)
|   |   |   +-- version.ex          # FileVersion schema
|   |   |
|   |   +-- memory/             # Memory System
|   |   |   +-- store.ex        # Conversation persistence
|   |   |   +-- search.ex       # FTS + structured filter queries
|   |   |   +-- context_builder.ex  # Assemble context for LLM (FTS-ranked + importance)
|   |   |   +-- entry.ex        # MemoryEntry schema
|   |   |
|   |   +-- resilience/         # Fault Tolerance
|   |   |   +-- circuit_breaker.ex  # Per-skill circuit breaker GenServer
|   |   |   +-- rate_limiter.ex     # Global + per-user rate limiting
|   |   |
|   |   +-- notifications/      # Error Alerting
|   |   |   +-- router.ex       # Severity routing + dedup
|   |   |   +-- google_chat.ex  # Webhook sender
|   |   |   +-- email.ex        # Email sender
|   |   |
|   |   +-- integrations/       # External Service Clients
|   |   |   +-- google/
|   |   |   |   +-- auth.ex     # OAuth2 / service account (goth)
|   |   |   |   +-- drive.ex    # Drive API client
|   |   |   |   +-- gmail.ex    # Gmail API client
|   |   |   |   +-- calendar.ex # Calendar API client
|   |   |   +-- hubspot.ex      # HubSpot API client
|   |   |   +-- openrouter.ex   # OpenRouter client (LLM + STT)
|   |   |   +-- elevenlabs.ex   # ElevenLabs TTS client (behind TTSClient behaviour)
|   |   |
|   |   +-- scheduler/          # Cron & Job System
|   |   |   +-- cron.ex         # Quantum scheduler config
|   |   |   +-- jobs.ex         # Oban job definitions
|   |   |
|   |   +-- schemas/            # Ecto Schemas
|   |       +-- conversation.ex
|   |       +-- message.ex
|   |       +-- skill_config.ex
|   |       +-- execution_log.ex
|   |       +-- file_version.ex
|   |       +-- file_operation_log.ex
|   |       +-- notification_channel.ex
|   |       +-- notification_rule.ex
|   |       +-- scheduled_task.ex
|   |       +-- user.ex
|   |
|   +-- assistant_web/          # Phoenix (webhooks only)
|       +-- router.ex
|       +-- controllers/
|       |   +-- telegram_controller.ex
|       |   +-- google_chat_controller.ex
|       |   +-- whatsapp_controller.ex
|       |   +-- health_controller.ex
|       +-- plugs/
|           +-- webhook_verification.ex  # Signature validation
|           +-- rate_limit.ex
|
+-- priv/
|   +-- repo/
|       +-- migrations/
|
+-- test/
|   +-- support/
|   |   +-- fixtures/           # Test data factories
|   |   +-- mocks.ex            # Mox mock definitions
|   |   +-- helpers.ex          # Test utilities
|   +-- assistant/
|   |   +-- channels/
|   |   +-- orchestrator/
|   |   +-- skills/
|   |   +-- files/
|   |   +-- memory/
|   |   +-- resilience/
|   +-- assistant_web/
|       +-- controllers/
|
+-- mix.exs
+-- Dockerfile
+-- .formatter.exs
+-- .env.example
```

### 10.2 Key Dependencies (mix.exs)

```elixir
defp deps do
  [
    # Web
    {:phoenix, "~> 1.8"},
    {:plug_cowboy, "~> 2.7"},
    {:jason, "~> 1.4"},

    # Database
    {:ecto_sql, "~> 3.12"},
    {:postgrex, ">= 0.0.0"},

    # Encryption
    {:cloak_ecto, "~> 1.3"},

    # Job processing & scheduling
    {:oban, "~> 2.18"},
    {:quantum, "~> 3.5"},

    # HTTP client
    {:req, "~> 0.5"},

    # Google Auth
    {:goth, "~> 1.4"},

    # Google APIs (official auto-generated)
    {:google_api_drive, "~> 0.27"},
    {:google_api_gmail, "~> 0.35"},
    {:google_api_calendar, "~> 0.24"},

    # Telegram
    {:telegex, "~> 1.8"},

    # Email (for notifications)
    {:swoosh, "~> 1.17"},

    # Markdown parsing
    {:earmark, "~> 1.4"},

    # OS process isolation (CLI tools with cgroup limits)
    {:muontrap, "~> 1.5"},

    # Temp directory management
    {:briefly, "~> 0.5"},

    # Monitoring
    {:telemetry, "~> 1.3"},
    {:telemetry_metrics, "~> 1.0"},

    # Dev/Test
    {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
    {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
    {:mox, "~> 1.2", only: :test},
    {:stream_data, "~> 1.1", only: :test},
    {:bypass, "~> 2.1", only: :test},
    {:excoveralls, "~> 0.18", only: :test}
  ]
end
```

### 10.3 Configuration Pattern

```elixir
# config/runtime.exs
import Config

if config_env() == :prod do
  config :assistant, Assistant.Repo,
    url: System.fetch_env!("DATABASE_URL"),
    pool_size: String.to_integer(System.get_env("POOL_SIZE", "10"))

  config :assistant, AssistantWeb.Endpoint,
    url: [host: System.fetch_env!("PHX_HOST"), port: 443, scheme: "https"],
    http: [port: String.to_integer(System.get_env("PORT", "4000"))],
    secret_key_base: System.fetch_env!("SECRET_KEY_BASE")

  config :assistant, Assistant.Integrations.OpenRouter,
    api_key: System.fetch_env!("OPENROUTER_API_KEY"),
    default_model: System.get_env("OPENROUTER_MODEL", "anthropic/claude-sonnet-4-20250514"),
    default_stt_model: System.get_env("OPENROUTER_STT_MODEL", "openai/whisper-large-v3")

  config :assistant, Assistant.Integrations.ElevenLabs,
    api_key: System.fetch_env!("ELEVENLABS_API_KEY"),
    voice_id: System.get_env("ELEVENLABS_VOICE_ID"),
    model_id: System.get_env("ELEVENLABS_MODEL_ID", "eleven_multilingual_v2")

  config :goth,
    json: System.fetch_env!("GOOGLE_SERVICE_ACCOUNT_JSON")

  config :assistant, Assistant.Integrations.HubSpot,
    api_key: System.fetch_env!("HUBSPOT_API_KEY")

  config :assistant, Assistant.Channels.Telegram,
    bot_token: System.fetch_env!("TELEGRAM_BOT_TOKEN")

  config :assistant, Assistant.Notifications,
    google_chat_webhook_url: System.fetch_env!("GOOGLE_CHAT_WEBHOOK_URL"),
    email_from: System.get_env("NOTIFICATION_EMAIL_FROM", "assistant@example.com")

  config :assistant, Assistant.Vault,
    ciphers: [
      default: {Cloak.Ciphers.AES.GCM,
        tag: "AES.GCM.V1",
        key: Base.decode64!(System.fetch_env!("CLOAK_KEY"))}
    ]
end
```

---

## 11. Implementation Roadmap

Aligned with the approved plan phasing.

### CODE Phase 1: Foundation

**Deliverables**:
- Phoenix project scaffold (mix phx.new, Ecto setup, Dockerfile)
- Core schemas + migrations (conversations, messages, skills, users, execution logs)
- Skill behaviour + registry + executor with iteration limits
- OpenRouter LLM client with tool-calling support
- Orchestration engine (agent loop with circuit breakers)
- Configuration system (runtime.exs with env vars)
- Health check endpoint

**Acceptance Criteria**:
- Application boots and connects to PostgreSQL
- Can create a conversation, send a message, get LLM response
- Tool calls are detected, validated, and dispatched
- Circuit breakers trip at configured limits
- Skills register and appear as tool definitions

### CODE Phase 2: First Channel + Integration

**Deliverables**:
- Google Chat adapter (webhook + bot responses)
- Google Drive client (service account via Goth) + file versioning workflow
- Memory system (conversation persistence + hybrid memory search with FTS, pgvector, tags, and structured filters)
- Basic skills: Drive read/write, markdown edit

**Acceptance Criteria**:
- Can receive and respond to messages on Google Chat
- File versioning workflow works end-to-end (pull/edit/archive/replace)
- File version audit trail in database
- Conversation history persisted and retrievable

### TEST Phase 1: Core Invariants

**Deliverables**:
- Invariant tests (file safety, loop limits, credential checks)
- Orchestrator unit tests
- Skill execution tests

**Acceptance Criteria**:
- All 5 invariants verified (no permanent delete, archive-before-replace, loop termination, no credentials in logs, webhook signature verification)
- Critical path coverage 90%+

### CODE Phase 3: Expand Skills + Channels

**Deliverables**:
- Telegram adapter, WhatsApp adapter
- Email skills (Gmail), Calendar skills, HubSpot skills
- Notification/alerting system (Google Chat webhook + email)
- Scheduler (Quantum cron + Oban jobs)

### CODE Phase 4: Voice + Polish

**Deliverables**:
- Voice channel adapter (audio in -> OpenRouter STT -> text -> orchestrator -> ElevenLabs TTS -> audio out)
- OpenRouter integration extension for STT (audio input via chat completions API)
- ElevenLabs integration client behind `TTSClient` behaviour (thin Req wrapper)
- Obsidian vault skills (via Drive)
- Markdown frontmatter manipulation (Earmark)

### TEST Phase 2: Full Suite

**Deliverables**:
- Integration tests (API contracts, channel adapters, DB)
- Security tests (webhook verification, credential leak checks)
- Load tests (concurrent conversations)

---

## 12. Risk Assessment

| Risk | Severity | Probability | Mitigation |
|------|----------|-------------|------------|
| Infinite agent loop | HIGH | MEDIUM | Three-tier circuit breakers with configurable limits |
| File loss during versioning | HIGH | LOW | Archive-before-replace with checksum verification + step-level audit log |
| LLM hallucinating invalid tool calls | MEDIUM | MEDIUM | Strict JSON schema validation before execution |
| Elixir ecosystem gaps (thin LLM/WhatsApp/HubSpot/ElevenLabs libs) | MEDIUM | MEDIUM | Write HTTP wrappers behind behaviours. Mox testing isolates from library quality. Req is excellent for HTTP. ElevenLabs TTS client is a thin wrapper (~40 lines of Req calls). |
| Team Elixir learning curve | MEDIUM | MEDIUM | Strong testing tools (Mox, StreamData) catch mistakes early. Behaviours enforce contracts. |
| Channel webhook downtime | MEDIUM | LOW | Channels retry; dead letter logging for debugging |
| OpenRouter downtime | MEDIUM | LOW | Graceful error message to user; abstract behind LLMClient behaviour |
| MuonTrap CLI escape | LOW | LOW | cgroup limits + timeout + restricted environment. CLI skills are few and controlled. |
| Notification flooding | LOW | MEDIUM | Rate limiter with deduplication window |
| Embedding generation cost/latency | LOW | MEDIUM | Generate embeddings asynchronously via Oban for non-blocking writes; cache query embeddings per turn; keep FTS fallback path if embedding API is temporarily unavailable. |
| Voice latency (STT->LLM->TTS) | MEDIUM | LOW | Voice is Phase 4. STT+LLM go through OpenRouter (single hop for transcribe+process), then ElevenLabs for TTS. Profile and optimize after core works. ElevenLabs streaming TTS helps. |
| ElevenLabs dependency for TTS | LOW | LOW | TTS is behind `TTSClient` behaviour. If ElevenLabs becomes unavailable or OpenRouter TTS matures, swap the implementation without changing the voice adapter. |

---

## 13. Open Questions

1. **Conversation timeout**: How long should idle conversations remain in memory before persisting state and terminating the GenServer? Recommend 15 minutes, configurable.

2. **Memory retention**: How long should memories persist? Recommend decay-based system where importance decreases over time unless reinforced by access. Tags and embeddings together support both explicit and semantic retrieval.

3. **LLM model selection**: Should the system support dynamic model selection per skill/conversation? OpenRouter makes multi-model trivial. Recommend configurable default with per-skill override capability.

4. **Voice latency optimization**: Consider streaming TTS from ElevenLabs (send text chunks as LLM streams back) vs. wait for complete LLM response before synthesizing. Streaming provides better UX but adds complexity. OpenRouter STT+LLM can share a single API call (audio input to chat completions), which reduces the first two hops to one.

5. **ElevenLabs voice selection**: Which ElevenLabs voice to use as default? Evaluate during PREPARE for Phase 4 based on naturalness, latency, and cost. Consider user-configurable voice preferences stored in `users.preferences` JSONB field.

6. **OpenRouter STT model selection**: Which specific model for STT via OpenRouter (e.g., `openai/whisper-large-v3`)? Evaluate during PREPARE for Phase 4 based on accuracy, latency, and language support.
