# Synaptic Assistant: Desktop & Cloud Architecture

> Revision 1 -- 2026-02-20
> Architect phase output for Tauri+Burrito desktop packaging and cloud product design.
> Grounded in four PREPARE-phase research documents (see docs/preparation/).

---

## 1. Executive Summary

This document defines the architecture for transforming Synaptic Assistant from a server-only Phoenix/LiveView application into a dual-distribution product:

1. **Desktop App** (v1) -- A standalone native application (macOS, Windows, Linux) using Tauri for the native shell and Burrito for BEAM binary packaging. Default storage is SQLite for zero-dependency local use, with optional PostgreSQL for power users.

2. **Cloud Product** (v2+) -- A hosted multi-tenant SaaS offering built on the same codebase, with row-level security (RLS) tenant isolation, Stripe metered billing, and Neon database provisioning.

**Core architectural principle**: A single Phoenix codebase serves both desktop and cloud modes, differentiated at runtime via a `SYNAPTIC_MODE` environment variable. Feature boundaries are enforced by the `.ee.` file pattern (FSL-1.1-ALv2 for community code, proprietary license for cloud-only features).

**Build order**: v1 = desktop app, v2 = pluggable storage, v3 = cloud product. But the architecture is designed for cloud from day one -- abstractions and module boundaries exist even before cloud code is written.

---

## 2. System Context (C4 Level 1)

### 2.1 Desktop Mode

```
+---------------------------------------------------------------+
|                   User's Machine                                |
|                                                                 |
|  +-----------------------------------------------------------+ |
|  |              Tauri Native Shell (Rust)                     | |
|  |  +------------------------------------------------------+ | |
|  |  |  OS WebView (WebKit / WebView2)                      | | |
|  |  |  Renders Phoenix LiveView at http://127.0.0.1:{port} | | |
|  |  +------------------------------------------------------+ | |
|  |                                                             | |
|  |  Sidecar: Burrito-wrapped Phoenix Release                  | |
|  |  +------------------------------------------------------+ | |
|  |  |  BEAM VM + Phoenix + LiveView + Skills + Orchestrator | | |
|  |  |  SQLite (default) or PostgreSQL (optional)            | | |
|  |  +------------------------------------------------------+ | |
|  +-----------------------------------------------------------+ |
|             |                    |                    |          |
|     +-------v------+   +--------v-------+   +--------v-------+ |
|     | SQLite DB     |   | Local Files    |   | API Keys       | |
|     | (~/.synaptic/ |   | (priv/workflows|   | (user-provided | |
|     |  data.db)     |   |  user data)    |   |  env vars)     | |
|     +---------------+   +----------------+   +----------------+ |
+---------------------------------------------------------------+
              |                    |
     +--------v--------+  +-------v---------+
     | OpenRouter API  |  | Google APIs     |
     | (LLM, STT, TTS) |  | (Gmail, Cal,   |
     |                  |  |  Drive)         |
     +------------------+  +-----------------+
```

### 2.2 Cloud Mode

```
                       +------------------+
                       |    Web Browser   |
                       |  (or Desktop App |
                       |   in cloud mode) |
                       +--------+---------+
                                |
                       +--------v---------+
                       |   Fly.io Edge    |
                       |   (SSL, routing) |
                       +--------+---------+
                                |
               +----------------v-----------------+
               |     Phoenix Cluster (Fly.io)     |
               |  +-----------------------------+ |
               |  | LiveView + Skills + Billing | |
               |  | Multi-tenant (RLS)          | |
               |  +-----------------------------+ |
               +--+----------+----------+--------+
                  |          |          |
          +-------v--+  +---v------+  +v-----------+
          | Neon PG  |  | Stripe   |  | Tigris S3  |
          | (tenant  |  | (billing)|  | (files)    |
          |  DBs)    |  |          |  |            |
          +----------+  +----------+  +------------+
```

---

## 3. Desktop App Architecture (Phase 1)

### 3.1 Tauri + Burrito Sidecar Model

The desktop app uses a **sidecar architecture**: Tauri provides the native window, and a Burrito-packaged Phoenix release runs as a managed child process.

#### Sidecar Lifecycle

```
Application Launch
       |
       v
  Tauri starts
       |
       v
  Spawn sidecar binary (Burrito-wrapped Phoenix)
       |
       v
  Sidecar picks dynamic port (port 0), writes to port file
       |
       v
  Tauri polls port file (up to 60s timeout)
       |
       v
  Port discovered -> HTTP health check on /health
       |
       v
  Health OK -> WebView navigates to http://127.0.0.1:{port}
       |
       v
  LiveView renders in native window
       |
       v
  [User works normally]
       |
       v
  Window close -> Tauri sends SIGTERM to sidecar
       |
       v
  Phoenix graceful shutdown -> SQLite WAL checkpoint -> exit
```

#### Port Discovery Mechanism

Phoenix writes the assigned port to a known file path immediately after the endpoint starts:

- **macOS/Linux**: `~/.synaptic-assistant/port`
- **Windows**: `%APPDATA%\Synaptic Assistant\port`

Tauri polls this file with a 200ms interval, up to 60s timeout. The file is deleted on clean shutdown to prevent stale port reads.

#### New Directory Structure

```
src-tauri/
  src/
    main.rs                 # Entry point: sidecar lifecycle, port polling
    lib.rs                  # Plugin setup (updater, shell, tray)
  Cargo.toml                # tauri, tauri-plugin-shell, tauri-plugin-updater
  tauri.conf.json           # Window config, sidecar def, updater, bundle settings
  capabilities/
    default.json            # Permissions: shell:allow-execute
  icons/                    # Platform app icons (all required sizes)
  binaries/                 # Symlinks to Burrito output (CI-generated)

scripts/
  build-sidecar.sh          # MIX_ENV=prod mix release assistant_desktop
  build-desktop.sh          # Full pipeline: sidecar + Tauri build
  rename-sidecar.sh         # Renames Burrito output to Tauri naming convention
```

### 3.2 Runtime Mode Detection

A single mechanism determines the operating mode at application boot. This replaces ad-hoc checks scattered through the codebase.

#### Module: `Assistant.Runtime`

```elixir
# lib/assistant/runtime.ex
defmodule Assistant.Runtime do
  @moduledoc false

  @type mode :: :desktop | :server

  @spec mode() :: mode()
  def mode do
    Application.get_env(:assistant, :runtime_mode, :server)
  end

  @spec desktop?() :: boolean()
  def desktop?, do: mode() == :desktop

  @spec server?() :: boolean()
  def server?, do: mode() == :server

  @spec data_dir() :: String.t()
  def data_dir do
    Application.get_env(:assistant, :desktop_data_dir, "priv")
  end
end
```

#### config/runtime.exs Additions

```elixir
# Desktop mode detection — BURRITO_TARGET is set by Burrito at build time
# and persists in the binary's environment
desktop_mode? = System.get_env("BURRITO_TARGET") != nil

if desktop_mode? do
  data_dir =
    case :os.type() do
      {:win32, _} ->
        Path.join(System.get_env("APPDATA", ""), "Synaptic Assistant")
      _ ->
        Path.join(System.user_home!(), ".synaptic-assistant")
    end

  File.mkdir_p!(data_dir)

  config :assistant,
    runtime_mode: :desktop,
    desktop_data_dir: data_dir

  # Dynamic port — let OS assign, write to file for Tauri
  config :assistant, AssistantWeb.Endpoint,
    http: [ip: {127, 0, 0, 1}, port: 0],
    server: true,
    check_origin: false

  # SQLite database (default desktop storage)
  config :assistant, Assistant.Repo,
    database: Path.join(data_dir, "synaptic.db"),
    pool_size: 5,
    journal_mode: :wal

  # Disable Oban in desktop mode (use Quantum + GenServer)
  config :assistant, Oban, testing: :manual
end
```

### 3.3 Pluggable Storage Layer (Phase 2)

The storage layer is abstracted behind a behaviour so desktop (SQLite) and cloud (PostgreSQL) modes can share the same application logic.

#### DatabaseAdapter Behaviour

```elixir
# lib/assistant/database_adapter.ex
defmodule Assistant.DatabaseAdapter do
  @moduledoc false

  @callback repo_module() :: module()
  @callback supports_oban?() :: boolean()
  @callback supports_rls?() :: boolean()
  @callback supports_vector?() :: boolean()
end
```

#### Implementations

```elixir
# lib/assistant/database_adapter/sqlite.ex
defmodule Assistant.DatabaseAdapter.SQLite do
  @moduledoc false
  @behaviour Assistant.DatabaseAdapter

  @impl true
  def repo_module, do: Assistant.Repo.SQLite

  @impl true
  def supports_oban?, do: false

  @impl true
  def supports_rls?, do: false

  @impl true
  def supports_vector?, do: false
end

# lib/assistant/database_adapter/postgres.ex
defmodule Assistant.DatabaseAdapter.Postgres do
  @moduledoc false
  @behaviour Assistant.DatabaseAdapter

  @impl true
  def repo_module, do: Assistant.Repo

  @impl true
  def supports_oban?, do: true

  @impl true
  def supports_rls?, do: true

  @impl true
  def supports_vector?, do: true
end
```

#### Repo Configuration

```elixir
# lib/assistant/repo/sqlite.ex — only compiled when ecto_sqlite3 is available
defmodule Assistant.Repo.SQLite do
  use Ecto.Repo,
    otp_app: :assistant,
    adapter: Ecto.Adapters.SQLite3
end
```

The existing `Assistant.Repo` (PostgreSQL) remains unchanged. The active repo is selected at startup in `application.ex` based on `Assistant.Runtime.mode/0`.

#### Migration Strategy

Migrations must work on both adapters. Constraints:

- Use only SQL features supported by both SQLite and PostgreSQL
- No PostgreSQL-specific types (enum, array, jsonb) in shared migrations
- PostgreSQL-specific migrations go in `priv/repo/pg_only_migrations/` and are skipped in desktop mode
- SQLite-specific migrations go in `priv/repo/sqlite_only_migrations/`
- Shared migrations use `priv/repo/migrations/` (the default)

### 3.4 Oban to Quantum+GenServer Migration (Desktop Mode)

In desktop mode, Oban is unavailable (it requires PostgreSQL). The two Oban workers must have alternative execution paths.

#### Current Oban Workers

| Worker | Queue | Purpose | Desktop Alternative |
|--------|-------|---------|---------------------|
| `WorkflowWorker` | `:scheduled` | Execute workflow prompts on cron schedule | Quantum direct execution (no Oban intermediary) |
| `CompactionWorker` | `:compaction` | Memory compaction, deduplicated by conversation_id | `GenServer`-based queue with dedup |

#### Desktop Job Runner

```elixir
# lib/assistant/scheduler/desktop_job_runner.ex
defmodule Assistant.Scheduler.DesktopJobRunner do
  @moduledoc false
  use GenServer

  # Provides Oban-like functionality for desktop mode:
  # - Job deduplication by key (replaces Oban unique constraints)
  # - Retry with exponential backoff (replaces Oban max_attempts)
  # - Concurrent execution limit per queue (replaces Oban queue config)
  #
  # This is NOT a full Oban replacement. It handles only the two
  # specific worker patterns used by Synaptic Assistant.
end
```

#### QuantumLoader Changes for Desktop Mode

In desktop mode, `QuantumLoader` executes workflows directly instead of enqueuing Oban jobs:

```elixir
# Change in build_quantum_job/3:
defp build_quantum_job(job_ref, cron, workflow_path) do
  relative_path = Path.relative_to_cwd(workflow_path)

  task_fn =
    if Assistant.Runtime.desktop?() do
      # Desktop: execute directly via DesktopJobRunner
      fn ->
        DesktopJobRunner.enqueue(:scheduled, WorkflowWorker, %{workflow_path: relative_path})
      end
    else
      # Server: enqueue via Oban (existing behavior)
      fn ->
        %{workflow_path: relative_path}
        |> WorkflowWorker.new()
        |> Oban.insert()
      end
    end

  Assistant.Scheduler.new_job()
  |> Quantum.Job.set_name(job_ref)
  |> Quantum.Job.set_schedule(Crontab.CronExpression.Parser.parse!(cron))
  |> Quantum.Job.set_task(task_fn)
end
```

#### Application.ex Changes

```elixir
# In start/2, replace static Oban child with conditional:
children = [
  # ... infrastructure children unchanged ...
] ++
  if Assistant.Runtime.desktop?() do
    [
      # Desktop: GenServer-based job runner replaces Oban
      Assistant.Scheduler.DesktopJobRunner
    ]
  else
    [
      # Server: Oban for persistent job queuing
      {Oban, Application.fetch_env!(:assistant, Oban)}
    ]
  end ++
  [
    # Quantum scheduler (both modes)
    Assistant.Scheduler,
    # ...remaining children...
  ]
```

### 3.5 Endpoint Changes

```elixir
# lib/assistant_web/endpoint.ex — Add port file writing callback
defmodule AssistantWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :assistant

  # ... existing plugs unchanged ...

  # Write port file for Tauri after endpoint starts (desktop mode only)
  def init(_key, config) do
    if Assistant.Runtime.desktop?() do
      # Register callback to write port after binding
      {:ok, Keyword.put(config, :on_start, &write_port_file/1)}
    else
      {:ok, config}
    end
  end

  defp write_port_file(_endpoint) do
    port = :ranch.get_port(AssistantWeb.Endpoint.HTTP)
    port_file = Path.join(Assistant.Runtime.data_dir(), "port")
    File.write!(port_file, Integer.to_string(port))
  end
end
```

### 3.6 NIF Cross-Compilation Risk (Phase 1 Blocker)

Two dependencies have C NIFs that Burrito must cross-compile via Zig:

| Dependency | NIF Type | Risk Level | Mitigation |
|------------|----------|------------|------------|
| `bcrypt_elixir` | C NIF | **HIGH** | Test on all 5 targets early. Fallback: `pbkdf2_elixir` (pure Elixir) |
| `muontrap` | C NIF | **MEDIUM** | Only used for process sandboxing. May not be needed in desktop mode |

**Recommendation**: Test NIF cross-compilation in CI during Phase 1 proof-of-concept. If bcrypt_elixir fails, switch to `pbkdf2_elixir` for desktop builds (it is pure Elixir and Burrito-safe). The server release can continue using bcrypt_elixir.

### 3.7 mix.exs Changes

```elixir
# New dependency
{:burrito, "~> 1.5", only: :prod}
{:ecto_sqlite3, "~> 0.17"}  # for desktop SQLite support

# New release configuration in project()
releases: [
  assistant: [
    steps: [:assemble]
  ],
  assistant_desktop: [
    steps: [:assemble, &Burrito.wrap/1],
    burrito: [
      targets: [
        macos_aarch64: [os: :darwin, cpu: :aarch64],
        macos_x86_64:  [os: :darwin, cpu: :x86_64],
        linux_x86_64:  [os: :linux,  cpu: :x86_64],
        linux_aarch64: [os: :linux,  cpu: :aarch64],
        windows_x86_64: [os: :windows, cpu: :x86_64]
      ]
    ]
  ]
]
```

---

## 4. Open-Source / Enterprise Boundary

### 4.1 License Structure

| Scope | License | Files |
|-------|---------|-------|
| Community code | FSL-1.1-ALv2 | `lib/assistant/**/*.ex` (default) |
| Cloud/enterprise features | Proprietary | `lib/assistant_ee/**/*.ex` |

All files default to FSL-1.1-ALv2 unless in the `_ee` namespace.

### 4.2 The `.ee.` File Pattern

Enterprise features live in a parallel directory tree under `lib/assistant_ee/`:

```
lib/
  assistant/                    # Community (FSL-1.1-ALv2)
    accounts/
    billing/                    # Basic billing types/schemas (shared)
    integrations/
    ...
  assistant_ee/                 # Enterprise (proprietary)
    tenants/                    # Multi-tenant management
      tenant.ex
      plan.ex
      feature_flags.ex
    billing/                    # Stripe integration, usage metering
      stripe_client.ex
      usage_tracker.ex
      metering.ex
    provisioning/               # Neon/Supabase database provisioning
      neon_client.ex
      connection_manager.ex
    admin/                      # Admin dashboard
      dashboard_live.ex
      tenant_monitor.ex
    teams/                      # Multi-user workspaces
      team.ex
      invitation.ex
      role.ex
```

### 4.3 Feature Gate Module

```elixir
# lib/assistant/feature_gate.ex
defmodule Assistant.FeatureGate do
  @moduledoc false

  @doc """
  Check if an enterprise feature is available.
  In community edition, always returns false.
  In cloud mode, checks tenant plan tier.
  """
  @spec enabled?(atom()) :: boolean()
  def enabled?(feature) do
    if Code.ensure_loaded?(AssistantEE.FeatureFlags) do
      AssistantEE.FeatureFlags.enabled?(feature)
    else
      false
    end
  end
end
```

### 4.4 Compilation Boundary

The `assistant_ee` code is conditionally compiled:

```elixir
# mix.exs
defp elixirc_paths(:test), do: ["lib", "test/support"] ++ ee_paths()
defp elixirc_paths(_), do: ["lib"] ++ ee_paths()

defp ee_paths do
  if System.get_env("SYNAPTIC_EDITION") == "enterprise" do
    ["lib/assistant_ee"]
  else
    []
  end
end
```

Community users never compile enterprise code. The `.ee.` directory is present in the repo (source-available) but gated by a different license and not compiled by default.

---

## 5. Cloud Product Architecture (Phase 3 -- Design Now, Build Later)

### 5.1 New Contexts

```
lib/assistant_ee/
  tenants/              # Tenant lifecycle, plan management
  billing/              # Stripe metered billing
  provisioning/         # Neon database provisioning
  admin/                # Admin dashboard, monitoring
  teams/                # Multi-user workspaces (v3)
```

### 5.2 Tenant Context (`AssistantEE.Tenants`)

#### Schemas

```elixir
# lib/assistant_ee/tenants/tenant.ex
schema "tenants" do
  field :name, :string
  field :slug, :string              # URL-safe identifier (subdomain)
  field :plan, Ecto.Enum, values: [:free, :starter, :pro, :enterprise]
  field :status, Ecto.Enum, values: [:active, :suspended, :churned]
  field :settings, :map, default: %{}
  field :stripe_customer_id, :string

  has_many :users, Assistant.Schemas.User
  has_one  :subscription, AssistantEE.Billing.Subscription

  timestamps(type: :utc_datetime)
end

# lib/assistant_ee/tenants/plan.ex
# Plan tier definitions with feature limits
@plans %{
  free:       %{storage_mb: 100, ai_tokens: 10_000, workflow_executions: 50},
  starter:    %{storage_mb: 1_024, ai_tokens: 100_000, workflow_executions: 500},
  pro:        %{storage_mb: 10_240, ai_tokens: 500_000, workflow_executions: :unlimited},
  enterprise: %{storage_mb: :unlimited, ai_tokens: :unlimited, workflow_executions: :unlimited}
}
```

### 5.3 Billing Context (`AssistantEE.Billing`)

#### Stripe Integration Architecture

```
User Action (LLM call, workflow run, file upload)
       |
       v
  UsageTracker GenServer (in-memory accumulator)
       |
       | (flush every 60 seconds)
       v
  usage_records table (local ledger)
       |
       | (Oban periodic worker, every 5 minutes)
       v
  Stripe.UsageRecord.create()
       |
       v
  Stripe auto-invoices at billing period end
```

#### Schemas

```elixir
# lib/assistant_ee/billing/subscription.ex
schema "billing_subscriptions" do
  belongs_to :tenant, AssistantEE.Tenants.Tenant
  field :stripe_subscription_id, :string
  field :stripe_price_ids, {:array, :string}
  field :status, Ecto.Enum, values: [:active, :past_due, :canceled, :trialing]
  field :current_period_start, :utc_datetime
  field :current_period_end, :utc_datetime
  timestamps(type: :utc_datetime)
end

# lib/assistant_ee/billing/usage_record.ex
schema "usage_records" do
  belongs_to :tenant, AssistantEE.Tenants.Tenant
  field :metric, Ecto.Enum, values: [:storage_bytes, :ai_tokens, :workflow_executions, :voice_minutes]
  field :quantity, :integer
  field :reported_to_stripe, :boolean, default: false
  field :stripe_usage_record_id, :string
  timestamps(type: :utc_datetime)
end
```

### 5.4 Row-Level Security (RLS) Tenant Isolation

#### How It Works

1. All multi-tenant tables have a `tenant_id` (UUID) column
2. PostgreSQL RLS policies enforce row-level filtering at the database level
3. A Plug sets `app.tenant_id` on every request using `SET LOCAL`
4. Queries are automatically filtered -- application code does not need `WHERE tenant_id = ?`

#### Implementation

```elixir
# lib/assistant_ee/plugs/tenant_scope.ex
defmodule AssistantEE.Plugs.TenantScope do
  @moduledoc false
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    case conn.assigns[:current_tenant] do
      nil -> conn
      tenant ->
        # SET LOCAL scopes to the current transaction only
        Ecto.Adapters.SQL.query!(
          Assistant.Repo,
          "SET LOCAL app.tenant_id = '#{tenant.id}'"
        )
        conn
    end
  end
end
```

#### RLS Policy (Migration)

```sql
-- Example for conversations table
ALTER TABLE conversations ENABLE ROW LEVEL SECURITY;
ALTER TABLE conversations FORCE ROW LEVEL SECURITY;

CREATE POLICY tenant_isolation ON conversations
  USING (tenant_id = current_setting('app.tenant_id')::uuid);
```

**Safety concern**: Connection pool reuse can leak tenant context. The `SET LOCAL` scoping ensures the setting is transaction-bound. Additionally, a `Repo.after_connect` callback resets the setting:

```elixir
# In Repo config:
config :assistant, Assistant.Repo,
  after_connect: {AssistantEE.Tenants, :reset_tenant_scope, []}
```

### 5.5 Provisioning Context (`AssistantEE.Provisioning`)

For paid tenants needing database isolation, Neon provides per-tenant databases:

```elixir
# lib/assistant_ee/provisioning/neon_client.ex
defmodule AssistantEE.Provisioning.NeonClient do
  @moduledoc false

  @doc """
  Create a new Neon project (database) for a tenant.
  Returns a connection string for Ecto.
  """
  @spec create_project(tenant_id :: String.t()) ::
    {:ok, %{project_id: String.t(), connection_string: String.t()}} |
    {:error, term()}
  def create_project(tenant_id) do
    # POST https://console.neon.tech/api/v2/projects
    # Returns connection string, project_id
  end
end
```

### 5.6 Web UI for Cloud Users

Cloud users access Synaptic via browser -- no desktop app needed. Since the app already uses Phoenix LiveView, the same UI renders in both contexts:

| Concern | Desktop Mode | Cloud Mode |
|---------|-------------|------------|
| Rendering | Tauri WebView | Standard browser |
| Auth | Local session (single user) | `SettingsUserAuth` (existing) |
| CSRF | Disabled (`check_origin: false`) | Enabled (Phoenix default) |
| Tenant routing | N/A | Subdomain: `{slug}.synaptic.cloud` |
| Static assets | Local Plug.Static | CDN via Cloudflare |

### 5.7 Desktop-Cloud Sync (v3, Design Sketch)

When a desktop user connects to the cloud:

```
Desktop (SQLite)                  Cloud (PostgreSQL)
      |                                 |
      +--- Export: SQLite -> JSON dump --+
      |                                 |
      +--- Import: validate + insert ---+
      |                                 |
      +--- Ongoing: conflict resolution +
           (last-write-wins for v1,
            CRDT for v3)
```

**v1 approach**: One-way migration tool. Export desktop SQLite to JSON, import into cloud PostgreSQL. No ongoing sync.

**v3 approach**: Bidirectional sync with conflict resolution. This is a significant engineering investment and should not be attempted before the cloud product is validated.

---

## 6. Component Diagram (C4 Level 2)

### 6.1 Desktop Mode Components

```
+------------------------------------------------------------------+
|                    Synaptic Assistant (Desktop)                    |
|                                                                    |
|  +-----------------+     +------------------+                      |
|  | Tauri Shell     |     | Phoenix Endpoint |                      |
|  | (Rust, ~100 LOC)|---->| (Bandit HTTP)    |                      |
|  |                 |     | Port: dynamic    |                      |
|  | - Window mgmt   |     +--------+---------+                      |
|  | - System tray   |              |                                |
|  | - Auto-updater  |     +--------v---------+                      |
|  +-----------------+     |    Router         |                      |
|                          | (LiveView routes) |                      |
|                          +--------+----------+                      |
|                                   |                                |
|          +----------+-------------+-------------+                  |
|          |          |             |             |                   |
|  +-------v---+ +---v-------+ +--v--------+ +--v----------+        |
|  | LiveView  | | Skills    | | Orchest-  | | Memory      |        |
|  | UI        | | Registry  | | rator     | | (Agent,     |        |
|  | (Settings,| | (email,   | | (Engine,  | |  Search,    |        |
|  |  Workflow | |  calendar,| |  SubAgent,| |  Store)     |        |
|  |  Editor)  | |  files,   | |  Loop)    | |             |        |
|  +-----------+ |  tasks,   | +-----------+ +-------------+        |
|                |  workflow) |                                      |
|                +------+-----+                                      |
|                       |                                            |
|          +------------+-------------+                              |
|          |            |             |                               |
|  +-------v---+ +-----v------+ +----v--------+                     |
|  | Quantum   | | Desktop    | | SQLite Repo |                     |
|  | Scheduler | | JobRunner  | | (ecto_      |                     |
|  | (cron)    | | (GenServer)| |  sqlite3)   |                     |
|  +-----------+ +------------+ +-------------+                     |
+------------------------------------------------------------------+
```

### 6.2 Cloud Mode Components

```
+------------------------------------------------------------------+
|                    Synaptic Assistant (Cloud)                      |
|                                                                    |
|  +------------------+                                              |
|  | Phoenix Endpoint |                                              |
|  | (Bandit HTTP)    |                                              |
|  | SSL via Fly.io   |                                              |
|  +--------+---------+                                              |
|           |                                                        |
|  +--------v---------+     +-----------------+                      |
|  |    Router         |     | TenantScope    |                      |
|  | (LiveView +       |---->| Plug           |                      |
|  |  API routes)      |     | (SET LOCAL     |                      |
|  +--------+----------+     |  tenant_id)    |                      |
|           |                +-----------------+                     |
|           |                                                        |
|  +--------v-------------------------------------------------+     |
|  |              Shared Application Core                      |     |
|  |  Skills | Orchestrator | Memory | Accounts | Scheduler    |     |
|  +--------+---+---+---+---+---+---+-----------+-------------+     |
|           |       |       |       |                                |
|  +--------v--+ +--v---+ +v------+ +v----------+                   |
|  | Oban      | | PG   | | Neon  | | Stripe    |                   |
|  | (job      | | Repo | | (per- | | (billing) |                   |
|  |  queue)   | | (RLS)| | tenant| |           |                   |
|  +-----------+ +------+ |  DBs) | +-----------+                   |
|                          +-------+                                 |
|                                                                    |
|  +---EE LAYER (proprietary, conditionally compiled)----------+    |
|  | Tenants | Billing | Provisioning | Admin | Teams          |    |
|  +-----------------------------------------------------------+    |
+------------------------------------------------------------------+
```

---

## 7. Data Architecture

### 7.1 Existing Schemas (Unchanged)

These schemas work in both desktop and cloud modes without modification:

| Schema | Table | Purpose |
|--------|-------|---------|
| `Conversation` | `conversations` | Chat sessions |
| `Message` | `messages` | Individual messages in conversations |
| `MemoryEntry` | `memory_entries` | Long-term memory storage |
| `MemoryEntity` | `memory_entities` | Entity graph nodes |
| `MemoryEntityRelation` | `memory_entity_relations` | Entity graph edges |
| `MemoryEntityMention` | `memory_entity_mentions` | Entity-to-entry links |
| `Task` | `tasks` | Task management |
| `TaskComment` | `task_comments` | Task comments |
| `TaskDependency` | `task_dependencies` | Task relationships |
| `TaskHistory` | `task_history` | Task audit trail |
| `ScheduledTask` | `scheduled_tasks` | Cron-scheduled tasks |
| `ExecutionLog` | `execution_logs` | Skill execution history |
| `FileVersion` | `file_versions` | File versioning |
| `FileOperationLog` | `file_operation_logs` | File operation audit |
| `NotificationRule` | `notification_rules` | Notification config |
| `NotificationChannel` | `notification_channels` | Notification targets |
| `SkillConfig` | `skill_configs` | Per-skill configuration |
| `User` | `users` | User profiles |

### 7.2 New Schemas for Cloud (EE Only)

| Schema | Table | Purpose | Phase |
|--------|-------|---------|-------|
| `Tenant` | `tenants` | Tenant records | 3 |
| `Subscription` | `billing_subscriptions` | Stripe subscription tracking | 3 |
| `UsageRecord` | `usage_records` | Metered usage ledger | 3 |
| `NeonProject` | `neon_projects` | Per-tenant database references | 3 |
| `Team` | `teams` | Multi-user workspaces | 3+ |
| `TeamMembership` | `team_memberships` | User-team associations | 3+ |

### 7.3 Cloud Table Modifications

For RLS, existing tables need a `tenant_id` column added in cloud mode:

```elixir
# priv/repo/pg_only_migrations/TIMESTAMP_add_tenant_id_to_all_tables.exs
def change do
  for table <- [:conversations, :messages, :memory_entries, :memory_entities,
                :tasks, :execution_logs, :file_versions, :notification_rules,
                :skill_configs] do
    alter table(table) do
      add :tenant_id, references(:tenants, type: :binary_id),
          null: true  # null = legacy/desktop rows
    end

    create index(table, [:tenant_id])
  end
end
```

### 7.4 SQLite Compatibility Constraints

When writing shared migrations, avoid:

| PostgreSQL Feature | SQLite Alternative |
|-------------------|--------------------|
| `jsonb` column type | `:map` (stored as JSON text) |
| Array columns | JSON array in text column |
| `Ecto.Enum` (PG enum) | String column with application validation |
| `citext` | Use `COLLATE NOCASE` |
| `tsvector` / FTS | SQLite FTS5 (different API) |
| `pgvector` | Not available; skip embedding search in desktop |

### 7.5 Memory Search Degradation in Desktop Mode

PostgreSQL hybrid search (FTS + pgvector + structured filters) is not available in SQLite. Desktop mode uses degraded search:

| Feature | PostgreSQL (Cloud) | SQLite (Desktop) |
|---------|-------------------|------------------|
| Full-text search | `tsvector` with ranking | SQLite FTS5 |
| Semantic search | `pgvector` embeddings | Not available |
| Structured filters | Standard SQL | Standard SQL |

This is an acceptable trade-off. Desktop users get keyword search; cloud users get semantic search. The `Memory.Search` module dispatches to the appropriate implementation based on `Assistant.Runtime.mode/0`.

---

## 8. API Specifications

### 8.1 Health Check (Existing)

```
GET /health
Response: 200 {"status": "ok"}
```

Used by Tauri for sidecar readiness polling (desktop) and Fly.io for health monitoring (cloud).

### 8.2 Stripe Webhook (Cloud Only)

```
POST /webhooks/stripe
Headers: Stripe-Signature: {sig}
Body: Stripe event JSON

Handles:
  - customer.subscription.created
  - customer.subscription.updated
  - customer.subscription.deleted
  - invoice.payment_succeeded
  - invoice.payment_failed
```

### 8.3 Desktop First-Run Setup API (Desktop Only)

```
POST /api/setup
Body: {
  "database": "sqlite" | "postgres",
  "postgres_url": "ecto://..." (optional, only if database=postgres)
}
Response: 200 {"status": "configured", "restart_required": true}
```

Exposed only when `Assistant.Runtime.desktop?()` is true and no database has been configured yet.

---

## 9. Technology Decisions

### 9.1 Decision Record

| Decision | Choice | Rationale | Alternatives Considered |
|----------|--------|-----------|------------------------|
| Desktop shell | Tauri v2 | Small binary (~3 MB), native WebView, auto-updater built in, Rust is minimal | Electron (too heavy, ~100 MB), Neutralinojs (less mature) |
| BEAM packaging | Burrito | Only maintained option for self-extracting BEAM binaries with NIF support | Bakeware (abandoned), manual release + installer |
| Desktop DB | SQLite via `ecto_sqlite3` | Zero-dependency, single-file, WAL mode for concurrency | Embedded PostgreSQL (too heavy), LiteFS (unnecessary) |
| Server DB | PostgreSQL (existing) | Already in use, supports Oban, pgvector, RLS | No change needed |
| Desktop job queue | Quantum + GenServer | Quantum already in project; GenServer handles the 2 worker patterns | Oban Lite (immature), EctoJob (requires PG) |
| License | FSL-1.1-ALv2 | Non-compete protection, 2-year Apache conversion, best community reception | BUSL (too long conversion), SSPL (toxic), AGPL (enterprise barrier) |
| EE boundary | `lib/assistant_ee/` directory | Clear filesystem separation, conditional compilation | Module naming convention only (harder to enforce) |
| Multi-tenancy | PostgreSQL RLS | Database-enforced isolation, single repo, lowest complexity | Triplex/schema-per-tenant (migration complexity), separate DBs (premature) |
| Billing | Stripe via `stripity_stripe` | Mature Elixir library, metered billing support, billing portal | Bling (newer, less proven), direct API (more code) |
| DB provisioning | Neon API | Scale-to-zero, claimable Postgres, per-tenant cost model | Supabase (redundant services), self-managed PG (ops burden) |
| Cloud hosting | Fly.io (initial) | Best Elixir support, SOC 2 + HIPAA, dns_cluster, low ops | Railway (fewer regions), AWS (too much ops for MVP) |

---

## 10. Security Architecture

### 10.1 Desktop Mode Security

| Concern | Mitigation |
|---------|------------|
| Local network exposure | Bind to `127.0.0.1` only; never `0.0.0.0` |
| WebView origin | `check_origin: false` is safe because endpoint is localhost-only |
| API key storage | Stored in SQLite with Cloak encryption (existing pattern). Vault key derived from OS keychain or user-provided passphrase |
| Database encryption | SQLite WAL mode; optional file-level encryption via SQLCipher (future) |
| Auto-update integrity | Tauri mandates Ed25519 signature verification on all updates |
| Sidecar tampering | Tauri verifies sidecar binary hash at launch |

### 10.2 Cloud Mode Security

| Concern | Mitigation |
|---------|------------|
| Tenant data isolation | PostgreSQL RLS policies enforced at DB level; `SET LOCAL` prevents cross-request leakage |
| Authentication | Existing `SettingsUserAuth` + tenant association |
| CSRF | Phoenix built-in CSRF tokens (already enabled) |
| API key management | Users bring their own API keys (stored encrypted per-tenant via Cloak) |
| Stripe webhook auth | Signature verification via `stripity_stripe` |
| Admin access | Separate admin auth with MFA (enterprise tier) |
| Data residency | Fly.io region selection per deployment; Neon region per tenant project |

### 10.3 Shared Security Concerns

| Concern | Mitigation |
|---------|------------|
| SQL injection | Ecto parameterized queries (existing) |
| XSS | Phoenix HTML escaping (existing); LiveView is server-rendered |
| Workflow file traversal | `resolve_path/1` validation in WorkflowWorker (existing) |
| YAML injection | `validate_field/2` in workflow create (existing) |
| Dependency supply chain | Hex.pm package verification; Dependabot for CVE alerts |

---

## 11. Deployment Architecture

### 11.1 Desktop Release Pipeline

```
Tag push (v*)
    |
    v
GitHub Actions: build-sidecar (5 parallel jobs)
    |
    |-- macos-latest (aarch64)    -> Burrito binary
    |-- macos-13 (x86_64)         -> Burrito binary
    |-- ubuntu-22.04 (x86_64)     -> Burrito binary
    |-- ubuntu-22.04-arm (aarch64)-> Burrito binary
    |-- windows-latest (x86_64)   -> Burrito binary
    |
    v
Rename binaries to Tauri sidecar naming convention
    |
    v
GitHub Actions: build-tauri (5 parallel jobs)
    |
    |-- macOS     -> .dmg (signed + notarized)
    |-- Linux     -> .AppImage, .deb
    |-- Windows   -> .msi, .exe (signed)
    |
    v
GitHub Release (draft, with latest.json for auto-updater)
```

### 11.2 Cloud Deployment

```
Push to main
    |
    v
GitHub Actions: test suite
    |
    v
fly deploy --app synaptic-cloud
    |
    v
Fly.io: rolling deployment (zero-downtime)
    |
    v
Health check passes -> traffic routed
```

### 11.3 Infrastructure (Cloud)

| Component | Service | Phase |
|-----------|---------|-------|
| App server | Fly.io (shared-cpu-1x, 256MB, 1-3 instances) | 3 |
| Platform DB | Neon Free / Launch | 3 |
| Tenant DBs | Neon (per-tenant projects) | 3 |
| Object storage | Tigris (Fly.io) | 3 |
| Redis | Upstash (PubSub, caching) | 3 |
| Email | Swoosh + Resend | 3 |
| Monitoring | Fly.io metrics + Sentry | 3 |
| CDN | Cloudflare (free tier) | 3 |

---

## 12. Implementation Roadmap

### Phase 1: Desktop Proof of Concept

**Goal**: Working desktop app on macOS ARM64 with SQLite.

**Deliverables**:
1. Add Burrito dependency and `assistant_desktop` release config to `mix.exs`
2. Add `ecto_sqlite3` dependency and `Repo.SQLite` module
3. Create `Assistant.Runtime` module for mode detection
4. Add desktop-mode config to `config/runtime.exs`
5. Create `DesktopJobRunner` GenServer to replace Oban in desktop mode
6. Modify `application.ex` for conditional children (Oban vs DesktopJobRunner)
7. Modify `QuantumLoader` for direct execution in desktop mode
8. Create minimal `src-tauri/` with sidecar lifecycle
9. Implement port file writing in endpoint
10. Build and test on macOS ARM64

**Acceptance criteria**: Double-click app, Phoenix boots with SQLite, LiveView renders in native window, workflows execute via Quantum+GenServer, clean shutdown.

**Phase 1 blocker**: NIF cross-compilation of bcrypt_elixir and muontrap. Test early.

**Dependencies**: None (greenfield desktop work).

### Phase 2: Pluggable Storage + Multi-Platform

**Goal**: Users can choose SQLite or PostgreSQL. Builds for all 5 platforms.

**Deliverables**:
1. Implement `DatabaseAdapter` behaviour with SQLite and Postgres implementations
2. Create dual migration paths (shared, pg-only, sqlite-only)
3. First-run setup screen for database selection
4. GitHub Actions CI for all 5 platform targets
5. Code signing setup (Apple Developer ID, Windows OV cert)
6. Auto-updater configuration and testing
7. SQLite FTS5 integration for desktop memory search

**Acceptance criteria**: CI produces signed installers for all 5 platforms. User can install, choose SQLite or PostgreSQL, and use all features. Auto-update works.

**Dependencies**: Phase 1 complete.

### Phase 3: Cloud Product

**Goal**: Hosted multi-tenant SaaS with billing.

**Deliverables**:
1. `AssistantEE.Tenants` context -- tenant CRUD, plan tiers
2. `AssistantEE.Billing` context -- Stripe integration, usage metering
3. Add `tenant_id` + RLS policies to all tables
4. `TenantScope` plug for request-level tenant isolation
5. Stripe webhook handler for subscription lifecycle
6. Usage tracking GenServer + Oban reporter
7. Fly.io deployment configuration
8. Subdomain-based tenant routing
9. Landing page / marketing site
10. Neon database provisioning for paid tenants

**Acceptance criteria**: User can sign up via web, subscribe via Stripe, use the assistant in browser with RLS isolation. Usage is metered and billed.

**Dependencies**: Phase 2 complete (pluggable storage layer must exist). EE compilation boundary must be established.

### Phase Dependency Graph

```
Phase 1 (Desktop PoC)
    |
    v
Phase 2 (Pluggable Storage + Multi-Platform)
    |
    v
Phase 3 (Cloud Product)
    |
    +---> Phase 3a: Teams + Workspaces
    +---> Phase 3b: Desktop-Cloud Sync
    +---> Phase 3c: SSO/SAML (enterprise gate)
```

---

## 13. Risk Assessment

| Risk | Probability | Impact | Phase | Mitigation |
|------|-------------|--------|-------|------------|
| NIF cross-compilation failure (bcrypt, muontrap) | Medium | **HIGH** | 1 | Test on all 5 targets in week 1. Fallback: `pbkdf2_elixir` (pure Elixir) for desktop |
| Ecto migration incompatibility (PG vs SQLite) | Medium | Medium | 2 | Strict shared migration constraints; adapter-specific migration directories |
| Oban features missing in DesktopJobRunner | Low | Medium | 1 | DesktopJobRunner only needs dedup + retry for 2 workers; scope is minimal |
| SQLite concurrency limits under heavy workflow load | Low | Low | 1 | WAL mode handles concurrent reads; writes are serialized (acceptable for single-user desktop) |
| RLS tenant_id leakage via connection pool | Low | **CRITICAL** | 3 | `SET LOCAL` (transaction-scoped); `after_connect` reset; comprehensive integration tests |
| Stripe metered billing complexity | Low | Medium | 3 | Start with storage metering only; add AI token metering after validation |
| Large binary size (Burrito + ERTS) | Medium | Low | 1 | Monitor; typical ~15-25 MB is acceptable |
| Tauri WebView rendering differences | Medium | Medium | 1 | Test LiveView on WebKit (macOS/Linux) and WebView2 (Windows) early |
| Desktop users expect zero-config (but PostgreSQL requires setup) | Medium | Medium | 1-2 | SQLite as default eliminates this; PostgreSQL is opt-in for power users |
| FSL license deters contributors | Low | Medium | All | FSL has best community reception among source-available licenses; 2-year Apache conversion builds trust |

---

## 14. Open Questions

These decisions can be deferred but should be resolved before their respective phases:

1. **Universal macOS binary vs separate Intel/ARM** -- Single download is simpler for users but larger (~40 MB vs ~20 MB). Defer to Phase 2.

2. **Windows certificate type** -- OV ($70-200/yr, initial SmartScreen warnings) vs EV ($200-400/yr, immediate trust). Defer to Phase 2.

3. **Desktop telemetry** -- Should the desktop app report anonymous usage analytics? Requires user consent flow. Defer to Phase 2.

4. **Embedded vector search for desktop** -- SQLite has no pgvector equivalent. Options: (a) skip semantic search on desktop, (b) use a pure-Elixir approximate nearest neighbor library, (c) bundle SQLite-VSS extension. Defer to Phase 2.

5. **Cloud admin dashboard** -- Build custom LiveView admin or use a library like `Backpex` or `LiveAdmin`? Defer to Phase 3.

---

## 15. Appendix: File Change Summary

### New Files

| File | Purpose | Phase |
|------|---------|-------|
| `lib/assistant/runtime.ex` | Mode detection (desktop vs server) | 1 |
| `lib/assistant/repo/sqlite.ex` | SQLite Ecto repo | 1 |
| `lib/assistant/database_adapter.ex` | Storage abstraction behaviour | 2 |
| `lib/assistant/database_adapter/sqlite.ex` | SQLite adapter impl | 2 |
| `lib/assistant/database_adapter/postgres.ex` | PostgreSQL adapter impl | 2 |
| `lib/assistant/scheduler/desktop_job_runner.ex` | GenServer job queue for desktop | 1 |
| `lib/assistant/feature_gate.ex` | EE feature availability check | 2 |
| `lib/assistant_ee/tenants/tenant.ex` | Tenant schema | 3 |
| `lib/assistant_ee/tenants/plan.ex` | Plan tier definitions | 3 |
| `lib/assistant_ee/billing/subscription.ex` | Stripe subscription schema | 3 |
| `lib/assistant_ee/billing/usage_record.ex` | Usage metering schema | 3 |
| `lib/assistant_ee/billing/stripe_client.ex` | Stripe API wrapper | 3 |
| `lib/assistant_ee/billing/usage_tracker.ex` | In-memory usage accumulator | 3 |
| `lib/assistant_ee/plugs/tenant_scope.ex` | RLS tenant context plug | 3 |
| `lib/assistant_ee/provisioning/neon_client.ex` | Neon database provisioning | 3 |
| `src-tauri/src/main.rs` | Tauri entry point + sidecar lifecycle | 1 |
| `src-tauri/Cargo.toml` | Rust dependencies | 1 |
| `src-tauri/tauri.conf.json` | Tauri configuration | 1 |
| `src-tauri/capabilities/default.json` | Tauri permissions | 1 |
| `scripts/build-sidecar.sh` | Burrito build script | 1 |
| `scripts/build-desktop.sh` | Full desktop build pipeline | 1 |
| `.github/workflows/desktop-release.yml` | CI/CD for desktop builds | 2 |

### Modified Files

| File | Change | Phase |
|------|--------|-------|
| `mix.exs` | Add burrito, ecto_sqlite3 deps; add assistant_desktop release; conditional elixirc_paths for EE | 1 |
| `config/runtime.exs` | Desktop mode detection, SQLite config, dynamic port | 1 |
| `lib/assistant/application.ex` | Conditional children (Oban vs DesktopJobRunner), conditional Goth | 1 |
| `lib/assistant_web/endpoint.ex` | Port file writing for Tauri, conditional check_origin | 1 |
| `lib/assistant/scheduler/quantum_loader.ex` | Desktop mode: direct execution instead of Oban enqueue | 1 |
| `lib/assistant_web/router.ex` | Add Stripe webhook route, setup API route, tenant routing (cloud) | 3 |
| `.gitignore` | Add `src-tauri/target/`, `burrito_out/` | 1 |
