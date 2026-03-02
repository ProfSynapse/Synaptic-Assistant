# Architecture: Admin Integration Settings

> Validated from [admin-integration-settings-plan.md](../plans/admin-integration-settings-plan.md)
> Architect validation pass — 2026-03-02

## Overview

Move integration API keys/tokens from environment variables to admin-configurable storage. Encrypted key-value table with ETS cache, env var fallback, and Postgres RLS defense-in-depth.

---

## System Context (C4 Level 1)

```
Admin (settings_user, is_admin=true)
    │
    ▼
┌──────────────────────────────────┐
│   Admin LiveView (AdminLive)     │
│   └── AdminIntegrations component│
└──────────┬───────────────────────┘
           │ put/delete/list_all
           ▼
┌──────────────────────────────────┐     ┌─────────────────────┐
│  IntegrationSettings (context)   │────►│  Postgres            │
│  ├── Cache (ETS GenServer)       │     │  integration_settings│
│  └── Registry (key definitions)  │     │  (encrypted, RLS)    │
└──────────┬───────────────────────┘     └─────────────────────┘
           │ get/1
           ▼
┌──────────────────────────────────┐
│  Consumers (~15 files)           │
│  Telegram, Slack, Discord,       │
│  OpenRouter, OpenAI, ElevenLabs, │
│  Google OAuth, Google Chat,      │
│  HubSpot                         │
└──────────────────────────────────┘
```

---

## Schema Design

### Table: `integration_settings`

| Column | Type | Constraints | Notes |
|--------|------|-------------|-------|
| `id` | `binary_id` | PK, autogenerate | |
| `key` | `string` | NOT NULL, unique index | Atom name as string, e.g. `"openrouter_api_key"` |
| `value` | `binary` | `Encrypted.Binary` | AES-GCM via Cloak.Ecto |
| `group` | `string` | NOT NULL, index | UI grouping, e.g. `"telegram"`, `"discord"` |
| `updated_by_id` | `binary_id` | FK → `settings_users.id`, nullable | Audit: which admin last changed it |
| `inserted_at` | `utc_datetime_usec` | | |
| `updated_at` | `utc_datetime_usec` | | |

**Indexes:**
- `unique_index(:integration_settings, [:key])`
- `index(:integration_settings, [:group])`

**RLS Policies (defense-in-depth):**
```sql
ALTER TABLE integration_settings ENABLE ROW LEVEL SECURITY;
CREATE POLICY admin_read ON integration_settings FOR SELECT
  USING (current_setting('app.is_admin', true) = 'true');
CREATE POLICY admin_write ON integration_settings FOR ALL
  USING (current_setting('app.is_admin', true) = 'true');
```

The context module sets `SET LOCAL app.is_admin = 'true'` inside transactions for admin operations. The Cache GenServer's warm query uses the same mechanism.

---

## Module Architecture

### New Modules

#### `Assistant.Schemas.IntegrationSetting`
Ecto schema. Fields: `key`, `value` (`Encrypted.Binary`), `group`, `updated_by_id`. Changeset validates key membership against Registry.

#### `Assistant.IntegrationSettings.Registry`
Compile-time registry of valid integration keys. Provides:
- Key validation (`valid_key?/1`)
- Group lookup (`group_for/1`)
- Key metadata: label, help text, secret flag, env var name
- Full key list for UI (`all_keys/0`, `keys_for_group/1`)

**Key groups (9 groups, 16 keys):**

| Group | Keys | Notes |
|-------|------|-------|
| `ai_providers` | `openrouter_api_key`, `openai_api_key` | System-level fallback keys |
| `google_workspace` | `google_oauth_client_id`, `google_oauth_client_secret` | Per-user OAuth uses these |
| `telegram` | `telegram_bot_token`, `telegram_webhook_secret` | |
| `slack` | `slack_client_id`, `slack_client_secret`, `slack_bot_token`, `slack_signing_secret` | |
| `discord` | `discord_bot_token`, `discord_public_key`, `discord_application_id` | New since plan consultation |
| `google_chat` | `google_chat_webhook_url` | |
| `hubspot` | `hubspot_api_key` | |
| `elevenlabs` | `elevenlabs_api_key`, `elevenlabs_voice_id` | |

**Excluded (env-var-only):**
- `google_credentials` / `GOOGLE_APPLICATION_CREDENTIALS` — JSON blob consumed at boot by Goth. Infrastructure-level, not user-facing.
- `google_cloud_project_number` — Used for JWT audience verification at boot.

#### `Assistant.IntegrationSettings.Cache`
ETS-backed GenServer following `Config.Loader` pattern.

- **Supervision**: Starts after `Repo`, before web endpoint in `Application` children list
- **Boot**: `warm/0` loads all rows from DB into ETS on `init/1`
- **PubSub**: Subscribes to `"integration_settings:changed"` for cache invalidation
- **ETS table name**: `:integration_settings_cache`

```
API:
  lookup(atom()) :: {:ok, String.t()} | :miss
  put(atom(), String.t()) :: :ok        # Write-through after DB write
  invalidate(atom()) :: :ok             # Delete single key from ETS
  invalidate_all() :: :ok               # Clear entire ETS table
  warm() :: :ok                         # Reload all from DB
```

#### `Assistant.IntegrationSettings`
Context module — primary public API.

```elixir
# Read — consumers call this (replaces Application.get_env)
@spec get(atom()) :: String.t() | nil

# Write — admin UI calls these
@spec put(atom(), String.t() | nil, binary_id | nil) ::
  {:ok, IntegrationSetting.t()} | {:error, Changeset.t()}
@spec delete(atom()) :: :ok

# Query — admin UI listing
@spec configured?(atom()) :: boolean()
@spec list_all() :: [%{
  key: atom(),
  source: :db | :env | :none,
  group: String.t(),
  masked_value: String.t() | nil,
  is_secret: boolean()
}]
```

#### `AssistantWeb.Components.AdminIntegrations`
LiveView function component (or LiveComponent) for the integrations section of AdminLive.

### Modified Modules

| Module | Change |
|--------|--------|
| `Assistant.Application` | Add `IntegrationSettings.Cache` to supervision tree after `Repo` |
| `AssistantWeb.AdminLive` | Import component, add event handlers for save/reset/expand |
| ~15 consumer files | Replace `Application.get_env(:assistant, :key)` with `IntegrationSettings.get(:key)` |

---

## Data Flow

### Read Path (Hot Path — No DB Queries)

```
Consumer calls IntegrationSettings.get(:telegram_bot_token)
    │
    ├─► Cache.lookup(:telegram_bot_token)
    │     └─► ETS :integration_settings_cache lookup
    │           ├─► {:ok, value}  →  return value
    │           └─► :miss         →  fall through
    │
    └─► Application.get_env(:assistant, :telegram_bot_token)
          ├─► value  →  return value (env var)
          └─► nil    →  return nil (not configured)
```

**Design invariant**: Reads NEVER hit the database. All DB values are loaded into ETS on boot (warm) and kept in sync via write-through.

### Write Path

```
Admin saves via LiveView
    │
    ▼
IntegrationSettings.put(:key, value, admin_id)
    │
    ├─1► Repo.transaction (with SET LOCAL app.is_admin = 'true')
    │      └─► INSERT ... ON CONFLICT (key) DO UPDATE
    │
    ├─2► Cache.put(:key, value)  [write-through to ETS]
    │
    └─3► PubSub.broadcast("integration_settings:changed", %{key: :key})
           └─► Other nodes: Cache.invalidate(:key) → next warm cycle repopulates
```

### Delete Path (Reset to Env Var)

```
Admin clicks "Reset to environment variable"
    │
    ▼
IntegrationSettings.delete(:key)
    │
    ├─1► Repo.delete (with RLS transaction)
    ├─2► Cache.invalidate(:key) [remove from ETS]
    └─3► PubSub.broadcast
```

After delete, `get(:key)` falls through ETS miss to `Application.get_env` — seamless revert.

### Nil Semantics

| State | `get(:key)` returns | UI shows |
|-------|---------------------|----------|
| DB row exists with value | DB value | "Database" badge (green) |
| DB row deleted / never created, env var set | Env var value | "Environment" badge (blue) |
| No DB row, no env var | `nil` | "Not configured" badge (gray) |

---

## Discord Integration Validation

Discord was added after the initial consultation (3 keys). Validation findings:

**Fits cleanly**: All three Discord keys follow the identical `Application.get_env(:assistant, :key)` pattern used by Telegram and Slack. The consumer migration is the same mechanical 1:1 replacement.

**Consumer files to migrate (Discord):**
- `lib/assistant/integrations/discord/client.ex` — `get_token/0` reads `:discord_bot_token`
- `lib/assistant_web/plugs/discord_auth.ex` — reads `:discord_public_key` for Ed25519 verification
- `config/runtime.exs` — loads all three from env vars (remains for fallback)

**`discord_application_id` note**: Currently loaded into config but not consumed by any code in `lib/`. The Registry correctly includes it — it will be needed for future slash command registration via the Discord API. Including it now avoids a follow-up migration.

**`discord_public_key` classification**: The plan marks it as `secret: true`. This is correct — while it's a "public" key in the cryptographic sense, it should still be treated as a sensitive configuration value (exposure would allow an attacker to verify they've correctly forged signatures, aiding reverse engineering). Masking in the UI is appropriate.

**No architectural impact**: Discord adds 3 keys to 1 group. The KV table design handles this with zero schema changes. The Registry just gains one more group entry. The ETS cache and PubSub invalidation are key-agnostic.

---

## Security Architecture

### Layers of Defense

| Layer | Mechanism | Protects Against |
|-------|-----------|-----------------|
| **Application** | `is_admin` check in LiveView + context module | Unauthorized access via web UI |
| **Database** | Postgres RLS via session variable | Bugs in app code that bypass admin checks |
| **Encryption** | Cloak AES-GCM (`Encrypted.Binary`) | Database dump / backup exposure |
| **UI** | Value masking (show `sk-or-...****`) | Shoulder surfing, screenshot leaks |
| **Audit** | `updated_by_id` FK on each row | Accountability for changes |

### RLS Implementation

The RLS approach uses Postgres session variables set per-transaction:

```elixir
# In IntegrationSettings context module
defp with_admin_transaction(fun) do
  Repo.transaction(fn ->
    Repo.query!("SET LOCAL app.is_admin = 'true'")
    fun.()
  end)
end
```

The Cache GenServer's `warm/0` also uses this pattern when loading initial data.

**Important**: The RLS policy uses `current_setting('app.is_admin', true)` (with `true` as the missing_ok parameter) so queries outside a transaction return `''` (empty string) rather than raising an error. This means unauthenticated queries silently return no rows rather than crashing.

---

## Boot Ordering

```
Application.start/2 supervision tree:
  1. Config.Loader          ← ETS config from YAML
  2. PromptLoader           ← Prompt templates
  3. Vault                  ← Cloak encryption (MUST be before Repo consumers)
  4. Repo                   ← Database connection pool
  5. DNSCluster, PubSub     ← Infrastructure
  6. maybe_goth()           ← Google Chat service account (env-var-only, excluded from this system)
  7. IntegrationSettings.Cache  ← NEW: warms ETS from DB (Repo must be up)
  8. Scheduler, Oban, ...   ← Job processing
  9. ... (other children)
  10. Endpoint               ← Web server (last)
```

**Between steps 4-7**: If any consumer tries to read an integration setting, ETS is empty, so `get/1` falls through to `Application.get_env` — identical to current behavior. Zero-downtime guarantee.

**Goth (step 6)**: Uses `google_credentials` from env var. This is excluded from the integration settings system and remains env-var-only. No boot ordering conflict.

---

## Consumer Migration Strategy

Mechanical 1:1 replacement across ~15 files:

```elixir
# Before:
Application.get_env(:assistant, :telegram_bot_token)

# After:
Assistant.IntegrationSettings.get(:telegram_bot_token)
```

Return type is identical: `String.t() | nil`. The fallback to env var means both old and new paths produce the same result during migration.

**Migration order** (recommended — simplest first, verify pattern works before tackling complex groups):
1. **Telegram** (2 keys, 2 files) — simplest, good canary
2. **Discord** (3 keys, 2 files) — similar pattern to Telegram
3. **ElevenLabs** (2 keys, ~1 file) — if consumer exists
4. **Google Chat** (1 key, ~1 file) — single key
5. **HubSpot** (1 key, ~1 file) — single key
6. **Slack** (4 keys, 3 files) — most keys, verify all paths
7. **Google OAuth** (2 keys, 2 files) — used by OAuth flow, test carefully
8. **AI Providers** (2 keys, 2 files) — OpenRouter + OpenAI system keys

---

## Validation Summary

| Aspect | Status | Notes |
|--------|--------|-------|
| KV table design | Sound | Extensible, proven pattern for heterogeneous config |
| ETS cache | Sound | Follows Config.Loader precedent, write-through eliminates DB on reads |
| PubSub invalidation | Sound | Works single-node and multi-node via Phoenix.PubSub |
| Registry | Sound | Compile-time validation, clean grouping, extensible |
| RLS | Sound | Defense-in-depth with session variable pattern |
| Discord accommodation | Sound | 3 keys fit cleanly, zero architectural impact |
| Boot ordering | Sound | Env var fallback covers the gap between Repo and Cache warm |
| Consumer migration | Sound | 1:1 replacement, incremental, backward compatible |
| Encryption | Sound | Reuses proven Cloak.Ecto pattern |
| Nil semantics | Sound | Clear distinction: no row = env var, empty string = disabled |

### Gaps Identified

None blocking. Two minor observations:

1. **`discord_application_id` is unused in code** — loaded into config but no consumer reads it yet. The Registry should still include it (future-proofing for slash command registration). Coders should add a comment in the Registry noting it's pre-provisioned.

2. **Logger.info on setting changes** — The plan mentions this under "Observability: Needs attention." The context module's `put/1` and `delete/1` should include `Logger.info` calls with the key name (not the value) and the admin's email. This is a coder-phase concern, not architectural.

---

## ADR: Integration Settings Storage

**Status**: Accepted (validated from plan)

**Context**: The project has 16 integration keys across 9 services, currently configured via environment variables. Self-hosters need a UI to configure integrations without editing env files or redeploying.

**Decision**: Single encrypted KV table + ETS cache + env var fallback.

**Alternatives Considered**:
- Per-integration tables: Rejected — rigid, migration overhead for each new service
- Typed columns: Rejected — sparse (16 keys, most rows would be NULL), hard to extend
- persistent_term cache: Rejected — global GC pause on updates, unpredictable update frequency
- Application.put_env at runtime: Rejected — officially discouraged for production, global mutable state

**Consequences**:
- Positive: Extensible (new key = new Registry entry, no migration), fast reads (ETS), secure (Cloak + RLS), backward compatible (env var fallback)
- Negative: Slightly less type safety than typed columns (mitigated by compile-time Registry validation)
