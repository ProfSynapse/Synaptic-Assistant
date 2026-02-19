# Architecture Validation: Phase 1 Foundation

> Post-PREPARE validation of architectural decisions, supervision tree, interface contracts,
> and integration of research findings from `remaining-research-2026-02-18.md`.
>
> Produced during ARCHITECT phase for Task #3.
> Date: 2026-02-18

---

## Table of Contents

1. [Finalized OTP Supervision Tree](#1-finalized-otp-supervision-tree)
2. [Sub-Agent Prompt Engineering Strategy](#2-sub-agent-prompt-engineering-strategy)
3. [Consolidated Interface Contracts](#3-consolidated-interface-contracts)
4. [Architectural Gaps and Amendments](#4-architectural-gaps-and-amendments)
5. [Schema Amendments](#5-schema-amendments)
6. [Implementation Guidance for CODE Phase](#6-implementation-guidance-for-code-phase)

---

## 1. Finalized OTP Supervision Tree

### 1.1 Complete Tree (Revision 7)

The previous tree (system-architecture.md Section 8, Revision 6) was incomplete. It omitted:

- Per-conversation `AgentSupervisor` (from sub-agent-orchestration.md Section 10.1)
- `Assistant.Config.Loader` GenServer (from config-design.md Section 4)
- `Assistant.Config.Watcher` GenServer (from config-design.md Section 6)
- `Assistant.Skills.Watcher` GenServer (from markdown-skill-system.md Section 7.4)
- Compaction and memory embedding Oban workers

The finalized tree:

```
Assistant.Application (Application, strategy: :one_for_one)
|
+-- Assistant.Repo (Ecto.Repo)
|     Restart: :permanent
|     Rationale: All persistence depends on DB connectivity.
|
+-- AssistantWeb.Endpoint (Phoenix.Endpoint)
|     Restart: :permanent
|     Rationale: Handles all HTTP/webhook traffic. Channels retry on miss.
|
+-- {Oban, oban_config()}
|     Restart: :permanent
|     Workers:
|       - Assistant.Workers.Notification (notification dispatch)
|       - Assistant.Workers.ScheduledTask (recurring task execution)
|       - Assistant.Workers.MemoryEmbedding (async embedding generation)
|       - Assistant.Workers.Compaction (continuous conversation compaction)
|     Rationale: Postgres-backed job queue with built-in retry/backoff.
|
+-- Assistant.Scheduler.Cron (Quantum)
|     Restart: :permanent
|     Rationale: Time-based cron triggers for scheduled skills/workflows.
|     Config: Global timezone from config; per-job timezone override.
|
+-- Assistant.Config.Loader (GenServer)
|     Restart: :permanent
|     Rationale: Loads config/config.yaml into ETS at boot. Must be
|     available before any orchestrator or sub-agent can resolve a model.
|     Boot order: Starts BEFORE Skills.Registry, ConversationSupervisor.
|
+-- Assistant.Config.Watcher (GenServer)
|     Restart: :permanent
|     Init args: [path: "config/config.yaml"]
|     Rationale: FileSystem-based watcher with 500ms debounce.
|     Triggers Config.Loader.reload/0 on file change.
|
+-- Assistant.Skills.Registry (GenServer)
|     Restart: :permanent
|     Rationale: ETS table of skill definitions loaded from skills/ directory.
|     Boot order: Starts AFTER Config.Loader (needs model info for validation).
|     Creates :skill_registry ETS table in init/1.
|
+-- Assistant.Skills.Watcher (GenServer)
|     Restart: :permanent
|     Init args: [path: "skills/"]
|     Rationale: FileSystem-based watcher for skill markdown files.
|     Triggers Skills.Registry.reload/0 on file change.
|
+-- Assistant.Skills.Executor.TaskSupervisor (Task.Supervisor)
|     Restart: :permanent
|     Rationale: Supervised async tasks for DIRECT skill execution
|     (single-loop mode, voice optimized path). Sub-agent skill execution
|     uses per-conversation AgentSupervisor instead.
|
+-- Assistant.Orchestrator.ConversationSupervisor (DynamicSupervisor)
|     Strategy: :one_for_one
|     Restart: :permanent
|     Rationale: Each conversation is independent; one crash does not
|     affect others.
|     |
|     +-- Assistant.Orchestrator.Engine (GenServer, per conversation)
|           Restart: :transient (only restart on abnormal exit)
|           Rationale: Conversations that end normally should not restart.
|           On crash: reload state from DB (messages, skill_executions).
|           |
|           +-- AgentSupervisor (Task.Supervisor, per conversation)
|                 Linked to Engine (started in Engine.init/1, stopped in terminate/2).
|                 NOT a child of DynamicSupervisor — linked to Engine lifecycle.
|                 Rationale: Sub-agents from different conversations are isolated.
|                 When Engine terminates, all its sub-agents are killed.
|                 |
|                 +-- SubAgent tasks (Task, per dispatched agent)
|
+-- Assistant.Resilience.CircuitBreaker.Supervisor (DynamicSupervisor)
|     Strategy: :one_for_one
|     Restart: :permanent
|     Rationale: Circuit breakers are independent per-skill.
|     |
|     +-- CircuitBreaker (GenServer, per skill)
|           Restart: :transient
|           State persistence: DB-backed for recovery across restarts.
|
+-- Assistant.Channels.Telegram (GenServer, if enabled)
|     Restart: :permanent (when using long-polling mode)
|     Rationale: Polls Telegram Bot API for updates. Restart recovers polling.
|
+-- Assistant.Integrations.Google.Auth (Goth)
|     Restart: :permanent
|     Rationale: Manages Google OAuth2 token refresh. All Google API calls
|     depend on this.
|
+-- Assistant.Notifications.Router (GenServer)
      Restart: :permanent
      Rationale: Severity routing + deduplication for ops notifications.
```

### 1.2 Boot Order

The supervision tree starts children in list order. Critical ordering constraints:

| Order | Process | Depends On | Why |
|-------|---------|------------|-----|
| 1 | Repo | (none) | Everything needs DB |
| 2 | Endpoint | Repo | Webhook traffic starts arriving |
| 3 | Oban | Repo | Job queue needs DB |
| 4 | Scheduler.Cron | (none) | Independent time triggers |
| 5 | Config.Loader | Repo | Must be ready before model resolution |
| 6 | Config.Watcher | Config.Loader | Watches file, triggers reload |
| 7 | Skills.Registry | Config.Loader | Needs model info for validation |
| 8 | Skills.Watcher | Skills.Registry | Watches files, triggers re-scan |
| 9 | Executor.TaskSupervisor | (none) | Standalone supervisor |
| 10 | ConversationSupervisor | Config.Loader, Skills.Registry | Engines need both to function |
| 11 | CircuitBreaker.Supervisor | (none) | Independent |
| 12 | Channel adapters | Endpoint | Need webhook routes ready |
| 13 | Google.Auth | (none) | Independent token management |
| 14 | Notifications.Router | (none) | Independent |

### 1.3 Restart Strategy Summary

| Supervisor | Strategy | Max Restarts | Period | Rationale |
|------------|----------|-------------|--------|-----------|
| Application | `:one_for_one` | 3 | 5s | Independent top-level services |
| ConversationSupervisor | `:one_for_one` | 10 | 60s | Conversations are independent; higher limit for multi-tenant load |
| CircuitBreaker.Supervisor | `:one_for_one` | 5 | 60s | Independent per-skill breakers |

### 1.4 Failure Scenarios (Updated)

| Failure | Supervisor Response | User Impact | Recovery |
|---------|-------------------|-------------|----------|
| Engine crash | ConversationSupervisor restarts (`:transient`) | Brief delay | Reload state from DB |
| AgentSupervisor crash | Linked to Engine — Engine also terminates, then restarts | Active sub-agents lost; conversation resumes | Engine restart recovers |
| SubAgent task crash | `Task.yield_many` returns `{:exit, ...}` | Single sub-agent fails | Orchestrator decides: retry/skip |
| Skill Task crash | TaskSupervisor captures exit | Skill fails gracefully | Error reported to Engine |
| Config.Loader crash | Application restarts it | Brief stale config | ETS survives (owned by Loader) |
| Config.Watcher crash | Application restarts it | Hot-reload temporarily unavailable | Reconnects to FileSystem |
| Skills.Registry crash | Application restarts it | Skills unavailable until re-scanned | Re-scans skills/ directory |
| Skills.Watcher crash | Application restarts it | Hot-reload temporarily unavailable | Reconnects to FileSystem |
| OpenRouter timeout | Engine handles in loop | "Having trouble connecting" | Retry with backoff in loop |
| CircuitBreaker crash | Supervisor restarts | Brief gap in tracking | Reload state from DB |

### 1.5 Key Design Decision: AgentSupervisor Lifecycle

The per-conversation `AgentSupervisor` is **linked** to the Engine, not a supervised child of the `ConversationSupervisor`. This is intentional:

- **Lifecycle coupling**: When an Engine terminates (normal or crash), its sub-agents must be killed immediately. Linking achieves this automatically.
- **No orphan sub-agents**: If AgentSupervisor were a sibling under DynamicSupervisor, an Engine crash could leave orphan sub-agents running.
- **Startup**: Engine calls `Task.Supervisor.start_link()` in `init/1`, storing the pid in `LoopState.agent_supervisor`.
- **Shutdown**: Engine calls `Task.Supervisor.stop(state.agent_supervisor)` in `terminate/2`.

This matches the pattern in sub-agent-orchestration.md Section 10.1.

---

## 2. Sub-Agent Prompt Engineering Strategy

### 2.1 Validated Template

Based on the preparer's research (remaining-research-2026-02-18.md Section 2), the sub-agent system prompt template is confirmed as:

```
You are a {domain} execution agent.

MISSION: {injected per dispatch}

SKILLS: Use only the provided tools. Each tool follows CLI syntax:
  skill.name --flag value --flag2 value2

OUTPUT FORMAT:
- After completing all tasks, summarize: what you did, files produced, and any errors.
- If blocked, immediately report: what failed, what you need, and what you've completed so far.

ERROR HANDLING:
- Retry failed skills once. If still failing, report the error and stop.
- Never fabricate data or assume missing parameter values.

If you need to call multiple tools and they are independent, call them all in parallel.
Only sequence tool calls when one depends on another's result.
```

**Token budget**: ~150-200 tokens for system prompt + ~50-100 tokens per skill schema.

### 2.2 Key Principles Applied

| Principle | How It Applies | Source |
|-----------|---------------|--------|
| Be Explicit, Not Verbose | Template is ~150 tokens, not ~500 | Anthropic Claude 4 best practices |
| Role + Mission + Constraints | Three-section structure | Preparer research Section 2 |
| Tool Definitions as Primary Context | CLI-style skill schemas carry instructional weight | Anthropic advanced tool use |
| No Progressive Discovery | Sub-agents receive fixed tool set at dispatch | Architecture decision |
| Parallel Tool Calling | Explicit instruction in template | Anthropic parallel tool calling guidance |
| No Anti-Laziness Prompts | No "be thorough" or "think carefully" | Claude 4.x best practices |
| Clear Error Escalation | "Report the error and stop" — no infinite retries | Preparer research Section 2 |

### 2.3 Orchestrator vs Sub-Agent Prompt Differences (Confirmed)

| Aspect | Orchestrator | Sub-Agent |
|--------|-------------|-----------|
| System prompt size | ~1,500-2,000 tokens | ~150-200 tokens |
| Tool count | 4 meta-tools (JSON) | 3-8 scoped skills (CLI) |
| Discovery | Progressive (`get_skill`) | Fixed at dispatch |
| Reasoning style | Plans, decomposes, coordinates | Executes, reports results |
| Error handling | Triages, re-dispatches, asks user | Retries once, escalates |
| Context includes | Summary + memory + history | Mission + scoped skills only |
| Response mode | Non-streaming (default) | Non-streaming |

### 2.4 Prompt Caching Integration

From preparer research Section 1:

- Place `cache_control` on the system prompt text part (not the message object)
- Orchestrator: 1-hour TTL (`"ttl": "1h"`) — extended conversations benefit from higher write cost (2x) paying back quickly
- Sub-agents: 5-min TTL (default `"ephemeral"`) — short-lived, frequent cache hits within a conversation turn
- Sort skill schemas alphabetically in scoped `use_skill` definition for cache key consistency
- Maximum 4 `cache_control` breakpoints per request (Anthropic limit)

**Recommended breakpoint placement for orchestrator**:

| Breakpoint | Content | TTL |
|------------|---------|-----|
| 1 | System prompt (identity + orchestration rules) | 1h |
| 2 | Tool definitions (get_skill, dispatch_agent, get_agent_results, message_agent) | 1h |
| 3 | Stable context (domain list, user preferences) | 5min |
| 4 | Conversation summary (if using compaction) | 5min |

**Recommended breakpoint placement for sub-agents**:

| Breakpoint | Content | TTL |
|------------|---------|-----|
| 1 | System prompt + scoped skill schemas (sorted alphabetically) | 5min |

Sub-agents only need one breakpoint. Two email-domain agents dispatched in the same conversation share the cached prefix.

---

## 3. Consolidated Interface Contracts

All interface contracts are currently spread across 4+ documents. This section consolidates them as the authoritative reference.

### 3.1 ConversationMessage (Channel -> Engine)

**Source**: system-architecture.md Section 5.2

```elixir
defmodule Assistant.Channels.Message do
  @type t :: %__MODULE__{
    id: String.t(),
    channel: :google_chat | :telegram | :slack | :whatsapp | :voice,
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

**Status**: Complete. No changes needed.

**Note**: The `channel` type now includes `:slack` (added per integration onboarding doc).

### 3.2 SkillContext (Engine -> Skill Executor)

**Source**: system-architecture.md Section 5.3

```elixir
defmodule Assistant.Skills.Context do
  @type t :: %__MODULE__{
    conversation_id: String.t(),
    user_id: String.t(),
    channel: atom(),
    workspace_path: String.t() | nil,
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

**Amendment**: Added `channel` field. The skill context should know which channel the request came from because:
- Voice channel needs concise responses
- File attachment handling differs by channel
- Some skills may format output differently per channel

### 3.3 SkillResult (Skill -> Engine/SubAgent)

**Source**: system-architecture.md Section 5.4

```elixir
defmodule Assistant.Skills.Result do
  @type t :: %__MODULE__{
    status: :ok | :error,
    content: String.t(),
    files_produced: [%{path: String.t(), name: String.t(), mime_type: String.t()}],
    side_effects: [atom()],
    metadata: map()
  }
end
```

**Status**: Complete. No changes needed.

### 3.4 SkillDefinition (Markdown Skill System)

**Source**: markdown-skill-system.md Section 7.2

```elixir
defmodule Assistant.Skills.SkillDefinition do
  @type t :: %__MODULE__{
    name: String.t(),           # "email.send"
    domain: String.t(),         # "email"
    action: String.t(),         # "send"
    description: String.t(),    # From YAML frontmatter
    handler: module() | nil,    # Elixir module implementing the handler behaviour
    schedule: String.t() | nil, # Cron expression (for scheduled skills)
    timezone: String.t() | nil, # IANA timezone (for scheduled skills)
    tags: [String.t()],
    author: String.t() | nil,
    raw_markdown: String.t(),   # Full markdown body (for LLM context)
    file_path: String.t()       # Absolute path to the .md file
  }
end
```

**Amendment**: Added `timezone` field per preparer's Quantum timezone research. Scheduled skills can specify per-skill timezone.

### 3.5 DomainIndex (SKILL.md Index)

**Source**: markdown-skill-system.md Section 7.2

```elixir
defmodule Assistant.Skills.DomainIndex do
  @type t :: %__MODULE__{
    domain: String.t(),         # "email"
    description: String.t(),    # From SKILL.md YAML frontmatter
    skills: [String.t()],       # ["email.send", "email.read", "email.search"]
    raw_markdown: String.t()    # Full SKILL.md body
  }
end
```

**Status**: Complete. No changes needed.

### 3.6 LoopState (Orchestrator Engine State)

**Source**: sub-agent-orchestration.md Section 5.4

```elixir
defmodule Assistant.Orchestrator.LoopState do
  @type t :: %__MODULE__{
    conversation_id: String.t(),
    user_id: String.t(),
    channel: atom(),
    turn_number: non_neg_integer(),
    messages: [map()],

    # Turn-scoped counters
    turn_orchestrator_calls: non_neg_integer(),
    turn_agents_dispatched: non_neg_integer(),
    turn_total_skill_calls: non_neg_integer(),

    # Agent tracking
    dispatched_agents: %{String.t() => agent_state()},
    agent_supervisor: pid(),

    # Conversation-scoped counters
    conversation_total_calls: non_neg_integer(),
    conversation_window_start: DateTime.t(),

    # Mode
    mode: :multi_agent | :single_loop | :direct,

    status: :running | :paused | :completed | :error
  }

  @type agent_state :: %{
    dispatch: map(),
    status: :pending | :running | :completed | :failed | :timeout | :skipped,
    result: String.t() | nil,
    transcript_tail: [String.t()],
    tool_calls_used: non_neg_integer(),
    control_messages: [String.t()],
    started_at: DateTime.t() | nil,
    completed_at: DateTime.t() | nil,
    duration_ms: non_neg_integer() | nil
  }
end
```

**Amendments**:
- Added `agent_supervisor` field (pid of per-conversation Task.Supervisor)
- Added `mode` field for voice-optimized routing (see Section 4.2)
- Added `:skipped` to `agent_state.status` (for dependency chain failures)

### 3.7 Agent Dispatch API (Orchestrator -> SubAgent)

**Source**: sub-agent-orchestration.md Section 2

The orchestrator dispatches sub-agents via the `dispatch_agent` tool. The dispatch parameters are:

```elixir
@type dispatch_params :: %{
  agent_id: String.t(),         # Unique identifier for this dispatch
  mission: String.t(),          # Natural language mission description
  skills: [String.t()],         # List of skill names to grant (e.g., ["email.send", "email.search"])
  depends_on: [String.t()],     # Agent IDs this agent depends on (default: [])
  max_tool_calls: pos_integer() | nil,  # Override default (5)
  model_override: keyword() | nil       # Optional: [prefer: :primary] or [id: "model-id"]
}
```

**Amendment**: Added `model_override` field. The orchestrator can select a different model tier for specific sub-agents (e.g., `:primary` for complex tasks, `:fast` for simple lookups). Resolves through `Config.Loader.model_for(:sub_agent, model_override)`.

### 3.8 Agent Results Response (SubAgent -> Orchestrator)

**Source**: sub-agent-orchestration.md Section 6.1

```elixir
@type agent_result :: %{
  status: :completed | :failed | :timeout | :skipped,
  result: String.t(),
  tool_calls_used: non_neg_integer(),
  duration_ms: non_neg_integer() | nil
}
```

**Status**: Complete. No changes needed.

### 3.9 Handler Behaviour (Skill Execution)

**Source**: markdown-skill-system.md Section 5

```elixir
defmodule Assistant.Skills.Handler do
  @doc "Execute the skill with parsed flags and execution context."
  @callback execute(flags :: map(), context :: Assistant.Skills.Context.t()) ::
    {:ok, Assistant.Skills.Result.t()} | {:error, term()}
end
```

**Status**: Complete. No changes needed.

### 3.10 Config Structs

**Source**: config-design.md Section 4.2

```elixir
defmodule Assistant.Config.Model do
  @type t :: %__MODULE__{
    id: String.t(),
    tier: :primary | :balanced | :fast | :cheap,
    description: String.t(),
    use_cases: [atom()],
    supports_tools: boolean(),
    max_context_tokens: pos_integer(),
    cost_tier: :low | :medium | :high
  }
end

defmodule Assistant.Config.VoiceConfig do
  @type t :: %__MODULE__{
    voice_id: String.t(),
    tts_model: String.t(),
    optimize_streaming_latency: 0..4,
    output_format: String.t(),
    voice_settings: %{
      stability: float() | nil,
      similarity_boost: float() | nil,
      style: float() | nil,
      speed: float() | nil
    }
  }
end
```

**Status**: Complete. No changes needed.

### 3.11 LLMClient Behaviour

**Source**: two-tool-architecture.md (implied), system-architecture.md ADR-005

```elixir
defmodule Assistant.Orchestrator.LLMClient do
  @doc "Send a chat completion request to OpenRouter."
  @callback chat(
    messages :: [map()],
    opts :: keyword()
  ) :: {:ok, llm_response()} | {:error, term()}

  @type llm_response :: %{
    type: :text | :tool_calls,
    content: String.t() | nil,
    calls: [tool_call()] | nil,
    usage: usage() | nil
  }

  @type tool_call :: %{
    id: String.t(),
    name: String.t(),
    arguments: map()
  }

  @type usage :: %{
    prompt_tokens: non_neg_integer(),
    completion_tokens: non_neg_integer(),
    total_tokens: non_neg_integer(),
    prompt_tokens_details: %{
      cached_tokens: non_neg_integer(),
      cache_write_tokens: non_neg_integer()
    } | nil
  }
end
```

**Note**: This behaviour was implicit across documents. Making it explicit here. The `usage` type includes `prompt_tokens_details` for cache monitoring (from preparer research Section 1).

### 3.12 ChannelAdapter Behaviour

**Source**: system-architecture.md Section 2 (Container A)

```elixir
defmodule Assistant.Channels.Adapter do
  @doc "Normalize an inbound channel-specific message to ConversationMessage."
  @callback normalize(raw_message :: map()) ::
    {:ok, Assistant.Channels.Message.t()} | {:error, term()}

  @doc "Send a response back to the channel."
  @callback send_response(
    channel_message_id :: String.t(),
    content :: String.t(),
    opts :: keyword()
  ) :: :ok | {:error, term()}

  @doc "Format content for channel-specific rendering (markdown, cards, etc.)."
  @callback format(content :: String.t(), format :: atom()) :: String.t()
end
```

**Note**: This behaviour was implied in system-architecture.md. Making it explicit here for CODE phase reference.

---

## 4. Architectural Gaps and Amendments

### 4.1 Gap: Timezone Support for Scheduled Tasks

**Discovery**: Preparer research (Section 3) confirmed that Quantum supports per-job timezone overrides via the `timezone` field on `Quantum.Job` structs. The `scheduled_tasks` table currently lacks a timezone column.

**Amendment**: Add `timezone TEXT NOT NULL DEFAULT 'UTC'` to the `scheduled_tasks` table. See Section 5.1 for the schema change.

**Impact on skill definitions**: Scheduled skills in markdown frontmatter should support an optional `timezone` field. Already reflected in SkillDefinition struct (Section 3.4 above).

**Impact on users table**: Add `timezone TEXT NOT NULL DEFAULT 'UTC'` to the `users` table (or `preferences` JSONB). When a user creates a scheduled task without specifying timezone, the system uses the user's configured timezone. See Section 5.2.

### 4.2 Gap: Voice-Optimized Routing Mode

**Discovery**: Preparer research (Section 4) shows that multi-agent orchestration adds ~2.5s of latency for voice interactions (an extra LLM round-trip for the sub-agent). For simple voice queries, this is unacceptable.

**Amendment**: The `LoopState` should include a `mode` field:

| Mode | When | Behavior |
|------|------|----------|
| `:multi_agent` | Default for text channels | Full orchestrator -> sub-agent pattern |
| `:single_loop` | Voice channel, simple requests | Orchestrator executes skills directly (no sub-agents) |
| `:direct` | Feature flag disabled or fallback | Original two-tool pattern |

**Decision logic**: When the Engine receives a message from the voice channel:
1. Default to `:single_loop` mode
2. The orchestrator can still dispatch sub-agents if it determines the task is complex
3. This is a hint, not a hard constraint

**Architecture impact**: The Engine must support both execution paths:
- `:multi_agent`: Orchestrator uses `dispatch_agent` / `get_agent_results` / `message_agent` tools
- `:single_loop`: Orchestrator uses `get_skill` + `use_skill` directly (original two-tool pattern)

The `use_skill` meta-tool and execution path from two-tool-architecture.md remains necessary for this mode. It is not replaced by the sub-agent architecture — it is an alternative execution mode.

**Feature flag**: Controlled by application config. Default: `:multi_agent` for text, `:single_loop` for voice.

### 4.3 Gap: Continuous Compaction Worker

**Discovery**: system-architecture.md references compaction as a concept but does not specify the Oban worker or its integration with the memory system.

**Amendment**: Define the compaction worker contract:

```elixir
defmodule Assistant.Workers.Compaction do
  use Oban.Worker, queue: :compaction, max_attempts: 3

  @doc """
  Runs after each conversation turn. Uses a small/fast model to:
  1. Generate an incremental fold summary of the conversation
  2. Detect topic shifts for memory extraction
  3. Store extracted memories via the memory system

  Triggered by Engine after each turn completes.
  """
  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"conversation_id" => conv_id}}) do
    # 1. Load recent messages since last compaction
    # 2. Call LLM (fast model via Config.Loader.model_for(:compaction))
    # 3. Update conversation summary
    # 4. Extract memories if topic shift detected
    :ok
  end
end
```

**Oban queue config**: `:compaction` queue with concurrency limit of 5 (prevent compaction from consuming all LLM capacity).

### 4.4 Gap: Memory Embedding Worker

**Discovery**: system-architecture.md Section 4.2 (Memories schema) defines the `embedding` column but does not specify how embeddings are generated asynchronously.

**Amendment**: Define the embedding worker contract:

```elixir
defmodule Assistant.Workers.MemoryEmbedding do
  use Oban.Worker, queue: :embeddings, max_attempts: 3

  @doc """
  Generates an embedding vector for a memory entry via OpenRouter embeddings API.
  Enqueued when a new memory is created (or on backfill).
  """
  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"memory_id" => memory_id}}) do
    # 1. Load memory content
    # 2. Call OpenRouter embeddings API
    # 3. Update memories.embedding and memories.embedding_model
    :ok
  end
end
```

### 4.5 Gap: Sentinel Gate Architecture

**Discovery**: system-architecture.md Section 7.4 references a "Sentinel gate" for evaluating mutating/destructive actions, but no architectural specification exists.

**Amendment**: The Sentinel is a synchronous check in the skill execution pipeline:

```
Engine -> SubAgent -> use_skill -> FlagValidator -> Sentinel Gate -> Handler.execute
```

**Sentinel contract**:

```elixir
defmodule Assistant.Resilience.Sentinel do
  @doc """
  Evaluates whether a skill execution should proceed.
  Uses a fast/cheap LLM model (Config.Loader.model_for(:sentinel))
  in a context-isolated call.

  Returns :ok or {:halt, reason}.
  Only invoked for skills with side effects (send, create, update, delete).
  Read-only skills (search, list, get) bypass the sentinel.
  """
  @spec evaluate(
    skill_name :: String.t(),
    flags :: map(),
    context :: Assistant.Skills.Context.t()
  ) :: :ok | {:halt, String.t()}
end
```

**When to invoke**: The Executor checks the skill's side effects. Skills that produce side effects (`:email_sent`, `:event_created`, `:file_updated`, `:task_created`, etc.) are routed through the Sentinel. Pure read operations are not.

**Phase 1 scope**: Sentinel is defined but implementation can be deferred to Phase 2. Phase 1 uses a no-op Sentinel that always returns `:ok`. The execution pipeline includes the Sentinel call point from the start for clean integration later.

### 4.6 Confirmation: Skill Execution from Sub-Agent Context

The sub-agent skill execution path must be clearly distinguished from the direct execution path:

| Path | Tool | Executor | Supervisor | When |
|------|------|----------|------------|------|
| Direct (single-loop) | `use_skill` in orchestrator context | `Skills.Executor` | `Skills.Executor.TaskSupervisor` (top-level) | `:single_loop` or `:direct` mode |
| Sub-agent | `use_skill` in sub-agent context | `SubAgent.execute_sub_agent_tools/3` | Per-conversation `AgentSupervisor` | `:multi_agent` mode |

Both paths go through the same `Handler.execute/2` call. The difference is which Task.Supervisor manages the execution and which context is passed.

---

## 5. Schema Amendments

### 5.1 scheduled_tasks: Add timezone Column

```sql
-- Amendment to system-architecture.md Section 4.2 (Scheduled Tasks)
ALTER TABLE scheduled_tasks ADD COLUMN timezone TEXT NOT NULL DEFAULT 'UTC';

-- The full CREATE TABLE becomes:
CREATE TABLE scheduled_tasks (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES users(id),
  skill_id VARCHAR(100) NOT NULL,
  parameters JSONB NOT NULL DEFAULT '{}',
  cron_expression VARCHAR(100) NOT NULL,
  timezone TEXT NOT NULL DEFAULT 'UTC',      -- NEW: IANA timezone identifier
  channel VARCHAR(50) NOT NULL,
  enabled BOOLEAN NOT NULL DEFAULT true,
  last_run_at TIMESTAMPTZ,
  next_run_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_scheduled_tasks_next_run ON scheduled_tasks(next_run_at) WHERE enabled = true;
```

### 5.2 users: Add timezone Column

```sql
-- Amendment to system-architecture.md Section 4.2 (Users)
ALTER TABLE users ADD COLUMN timezone TEXT NOT NULL DEFAULT 'UTC';

-- The full CREATE TABLE becomes:
CREATE TABLE users (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  external_id VARCHAR(255) NOT NULL,
  channel VARCHAR(50) NOT NULL,
  display_name VARCHAR(255),
  timezone TEXT NOT NULL DEFAULT 'UTC',      -- NEW: IANA timezone identifier
  preferences JSONB DEFAULT '{}',
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE(external_id, channel)
);
```

**Rationale**: Timezone is important enough to be a first-class column rather than buried in JSONB `preferences`. It is queried frequently (every scheduled task creation) and should be indexable.

### 5.3 skill_executions: Agent Tracking Columns

Already defined in sub-agent-orchestration.md Section 12.2, but confirmed here for completeness:

```sql
ALTER TABLE skill_executions ADD COLUMN agent_id VARCHAR(100);
ALTER TABLE skill_executions ADD COLUMN agent_mission TEXT;
ALTER TABLE skill_executions ADD COLUMN parent_execution_id UUID REFERENCES skill_executions(id);

CREATE INDEX idx_skill_executions_agent ON skill_executions(agent_id)
  WHERE agent_id IS NOT NULL;
CREATE INDEX idx_skill_executions_parent ON skill_executions(parent_execution_id)
  WHERE parent_execution_id IS NOT NULL;
```

---

## 6. Implementation Guidance for CODE Phase

### 6.1 Phase 1 Scope Confirmation

Phase 1 (Foundation) should deliver:

1. **OTP Application skeleton** with the full supervision tree from Section 1.1
2. **Config system**: Config.Loader + Config.Watcher + ETS-backed reads + YAML parsing
3. **Skill system**: Skills.Registry + Skills.Watcher + SkillDefinition/DomainIndex structs + Handler behaviour + file-based discovery
4. **Orchestrator foundation**: Engine GenServer + LoopState + LLMClient behaviour + context assembly
5. **Sub-agent execution**: SubAgent module + AgentScheduler + per-conversation AgentSupervisor
6. **Meta-tools**: get_skill + dispatch_agent + get_agent_results + message_agent + use_skill
7. **Database schema**: All tables from Section 5 (migrations)
8. **Channel adapter**: ChannelAdapter behaviour + one concrete adapter (Telegram or Google Chat)

### 6.2 What Is NOT in Phase 1

- Individual skill handler implementations (email, calendar, etc.) — Phase 2+
- Sentinel gate implementation (no-op stub in Phase 1)
- Voice pipeline (STT/TTS) — Phase 4
- Memory embedding pipeline — Phase 2
- Compaction worker (contract defined, implementation Phase 2)
- File versioning/SyncManager — Phase 3
- Notification system — Phase 2

### 6.3 Critical Implementation Notes

1. **ETS table ownership**: The process that creates an ETS table owns it. If that process dies, the table is destroyed. Config.Loader and Skills.Registry must own their respective ETS tables. This is why they are top-level supervised processes, not started lazily.

2. **FileSystem dependency**: Both Config.Watcher and Skills.Watcher depend on the `file_system` hex package. On macOS this uses `fsevent`; on Linux it uses `inotify`. Both watchers should handle the `:file_event` message pattern from FileSystem.

3. **Per-conversation AgentSupervisor cleanup**: The Engine's `terminate/2` callback MUST stop the AgentSupervisor. If the Engine is killed (`:brutal_kill`), the linked AgentSupervisor will also be killed, which is the desired behavior.

4. **Prompt caching**: The `RequestBuilder` module should construct message arrays with `cache_control` breakpoints. Content ordering matters: stable prefix first, variable suffix last. See two-tool-architecture.md Section 6A for the full RequestBuilder module design.

5. **Alphabetical skill sorting**: When building the scoped `use_skill` tool definition for sub-agents, sort skill names alphabetically. This ensures cache key consistency across sub-agents with the same skill set.

6. **Mode field in LoopState**: Initialize to `:multi_agent` by default. Override to `:single_loop` when `channel == :voice`. The Engine should support both tool sets (orchestrator tools for multi-agent, use_skill for single-loop).

---

## Self-Verification Checklist

- [x] All PREPARE phase requirements addressed (OTP tree, prompt engineering, interfaces, gaps)
- [x] Each component has single, clear responsibility
- [x] All interfaces well-defined with Elixir typespecs
- [x] Non-functional requirements embedded (fault tolerance via supervision, performance via caching, security via Sentinel)
- [x] Architecture is testable (behaviours enable mocking, process isolation enables unit testing)
- [x] Implementation path is clear (Phase 1 scope explicitly defined)
- [x] Documentation is unambiguous (consolidated contracts, schema amendments explicit)
- [x] OTP supervision tree includes all discovered components
- [x] Boot order dependencies documented
- [x] Restart strategies specified for all supervisors
- [x] Failure scenarios cover all new components
- [x] Schema amendments are backward-compatible (new columns with defaults)
- [x] Voice latency optimization has a concrete architectural solution (mode field)
- [x] Prompt caching strategy validated against preparer findings
