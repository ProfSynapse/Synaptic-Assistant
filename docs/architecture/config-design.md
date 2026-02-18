# Configuration Design: Model Roster, Voice & HTTP

> Revision 2 — 2026-02-17
> - `model_for/2` now accepts optional override opts (`prefer:` tier, `id:` explicit model).
> - Config watcher is a standalone `Assistant.Config.Watcher` GenServer (separate from Skills.Watcher).

## 1. Overview

The assistant uses a YAML configuration file (`config/config.yaml`) as the single source of truth for:

1. **Model roster** — curated list of OpenRouter LLM models with tier, use-case, and cost metadata.
2. **Default role assignments** — which model tier to use for orchestrator, sub-agent, compaction, sentinel, and audio transcription.
3. **Voice configuration** — ElevenLabs TTS settings (voice, model, latency, output format, voice tuning).

This file is human-editable, version-controlled, and hot-reloadable. Adding or removing models from the roster requires only a config change — no code changes.

Sensitive values (API keys) remain in `runtime.exs` via environment variables. The YAML file uses `${ENV_VAR}` interpolation only for deployment-varying values like `ELEVENLABS_VOICE_ID`.

---

## 2. YAML Schema

### 2.1 Top-Level Structure

```yaml
defaults:     # Role -> tier mapping
models:       # List of model entries
voice:        # ElevenLabs TTS configuration
```

### 2.2 `defaults` Section

Maps each system role to a model tier. The `ConfigLoader` resolves a role to the first model in the roster matching that tier.

```yaml
defaults:
  orchestrator: primary         # Main orchestration LLM
  sub_agent: balanced           # Default sub-agent model
  compaction: fast              # Continuous summary compaction
  sentinel: fast                # Prompt injection / safety classifier
  audio_transcription: fast     # STT-capable model
```

**Type**: `map(atom, atom)` where values are tier atoms.

### 2.3 `models` Section

Each entry describes one OpenRouter model.

```yaml
models:
  - id: "anthropic/claude-sonnet-4-6"
    tier: primary
    description: "Claude Sonnet 4.6 — top-tier reasoning and tool calling"
    use_cases:
      - orchestrator
      - sub_agent
    supports_tools: true
    max_context_tokens: 200000
    cost_tier: high
```

**Field reference:**

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `id` | string | Yes | OpenRouter model identifier (`provider/model-name`) |
| `tier` | enum | Yes | `primary`, `balanced`, `fast`, `cheap` |
| `description` | string | Yes | Human-readable summary |
| `use_cases` | list(atom) | Yes | Eligible roles: `orchestrator`, `sub_agent`, `compaction`, `sentinel`, `audio_transcription` |
| `supports_tools` | boolean | Yes | Whether the model supports OpenRouter tool/function calling |
| `max_context_tokens` | integer | Yes | Maximum context window size |
| `cost_tier` | enum | Yes | `low`, `medium`, `high` — relative cost classification |

**Validation rules (enforced at load time):**

- `id` must be a non-empty string matching `provider/model-name` pattern.
- `tier` must be one of `:primary`, `:balanced`, `:fast`, `:cheap`.
- `use_cases` must be a non-empty list of recognized atoms.
- `cost_tier` must be one of `:low`, `:medium`, `:high`.
- `max_context_tokens` must be a positive integer.
- Each default role in `defaults` must map to a tier that has at least one model in the roster.

### 2.4 `voice` Section

ElevenLabs TTS configuration.

```yaml
voice:
  voice_id: "${ELEVENLABS_VOICE_ID}"
  tts_model: "eleven_flash_v2_5"
  optimize_streaming_latency: 3
  output_format: "mp3_44100_128"
  voice_settings:
    stability: 0.5
    similarity_boost: 0.75
    style: 0.0
    speed: 1.0
```

**Field reference:**

| Field | Type | Required | Default | Description |
|-------|------|----------|---------|-------------|
| `voice_id` | string | Yes | — | ElevenLabs voice ID (supports `${ENV}` interpolation) |
| `tts_model` | string | Yes | — | ElevenLabs model ID (e.g. `eleven_flash_v2_5`, `eleven_multilingual_v2`) |
| `optimize_streaming_latency` | integer | No | `0` | 0 (max quality) to 4 (min latency) |
| `output_format` | string | No | `mp3_44100_128` | Audio output format |
| `voice_settings.stability` | float | No | voice default | 0.0–1.0 |
| `voice_settings.similarity_boost` | float | No | voice default | 0.0–1.0 |
| `voice_settings.style` | float | No | `0.0` | 0.0–1.0 (style exaggeration) |
| `voice_settings.speed` | float | No | `1.0` | Speech speed multiplier |

---

## 3. Environment Variable Interpolation

The YAML loader resolves `${ENV_VAR}` patterns in string values before parsing.

**Algorithm:**

1. Read the raw YAML file as a string.
2. Apply regex replacement: `~r/\$\{([A-Z_][A-Z0-9_]*)\}/` — replace each match with `System.get_env(var_name)`.
3. If an env var is not set, raise `RuntimeError` at boot with a clear message identifying the missing variable.
4. Parse the interpolated string as YAML.

**Scope:** Interpolation is intentionally limited to string values in the YAML. It is not a general templating engine. The primary use case is `ELEVENLABS_VOICE_ID` — allowing different voices per deployment without editing the config file.

**Security:** API keys (OpenRouter, ElevenLabs, Google) are NOT in this file. They live in `runtime.exs` and are loaded directly from env vars into application config. The YAML file only holds non-secret, deployment-varying values.

---

## 4. Elixir Module Interface

### 4.1 `Assistant.Config.Loader`

GenServer responsible for loading, validating, caching, and hot-reloading the model roster and voice configuration.

```elixir
defmodule Assistant.Config.Loader do
  @moduledoc """
  Loads and serves model roster and voice configuration from config/config.yaml.
  Backed by ETS for fast concurrent reads. GenServer coordinates reloads.
  """

  use GenServer

  @type model_override :: [prefer: atom(), id: String.t()]

  # --- Public API (read from ETS, no GenServer call) ---

  @doc "Returns all configured models as a list of Model structs."
  @spec all_models() :: [Assistant.Config.Model.t()]
  def all_models

  @doc """
  Returns the model for a given use-case role.

  Without overrides, resolves via defaults: role -> tier -> first matching model.
  With overrides, the orchestrator can select a different model per dispatch:

    - `prefer: :primary`  — use the given tier instead of the role's default tier
    - `id: "anthropic/claude-sonnet-4-6"` — select an explicit model by ID (must exist in roster)

  If `id:` is given, `prefer:` is ignored.
  Returns `nil` if no matching model is found.
  """
  @spec model_for(use_case :: atom(), opts :: model_override()) :: Assistant.Config.Model.t() | nil
  def model_for(use_case, opts \\ [])

  @doc "Returns all models matching the given tier."
  @spec models_by_tier(tier :: atom()) :: [Assistant.Config.Model.t()]
  def models_by_tier(tier)

  @doc "Returns the voice configuration as a VoiceConfig struct."
  @spec voice_config() :: Assistant.Config.VoiceConfig.t()
  def voice_config

  # --- Reload API (goes through GenServer for coordination) ---

  @doc "Reloads configuration from disk. Called by FileSystem watcher on file change."
  @spec reload() :: :ok | {:error, term()}
  def reload
end
```

### 4.2 Struct Definitions

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

  defstruct [:id, :tier, :description, :use_cases, :supports_tools,
             :max_context_tokens, :cost_tier]
end

defmodule Assistant.Config.VoiceConfig do
  @type t :: %__MODULE__{
    voice_id: String.t(),
    tts_model: String.t(),
    optimize_streaming_latency: 0..4,
    output_format: String.t(),
    voice_settings: voice_settings()
  }

  @type voice_settings :: %{
    stability: float() | nil,
    similarity_boost: float() | nil,
    style: float() | nil,
    speed: float() | nil
  }

  defstruct [:voice_id, :tts_model, :optimize_streaming_latency,
             :output_format, :voice_settings]
end
```

---

## 5. ETS-Backed Storage Design

### 5.1 Table Layout

A single named ETS table (`:assistant_config`) stores the parsed configuration:

| Key | Value |
|-----|-------|
| `:models` | `[%Model{}, ...]` |
| `:defaults` | `%{orchestrator: :primary, sub_agent: :balanced, ...}` |
| `:voice` | `%VoiceConfig{}` |
| `:loaded_at` | `DateTime.t()` |

### 5.2 Read Path

All public API functions (`all_models/0`, `model_for/2`, etc.) read directly from ETS via `:ets.lookup/2`. No GenServer call is involved in the read path, ensuring:

- Constant-time lookups regardless of concurrent readers.
- No bottleneck on the GenServer process.
- Safe concurrent access from multiple orchestrator/sub-agent processes.

### 5.3 Atomic Reload Strategy

On reload, the GenServer:

1. Reads and parses the YAML file (with env var interpolation).
2. Validates the parsed data against the schema rules.
3. If validation passes, atomically updates ETS entries via `:ets.insert/2` (which is atomic per key).
4. Updates `:loaded_at` timestamp.
5. If validation fails, logs a warning and keeps the previous configuration. Returns `{:error, reason}`.

**Why not table swap?** ETS `:ets.insert/2` on a `:set` table atomically replaces the value for a given key. Since we have a small fixed set of keys (`:models`, `:defaults`, `:voice`, `:loaded_at`), a single `insert` call with a list of tuples is sufficient. Readers may briefly see a mix of old/new values for different keys during the insert, but this is acceptable because:

- Reloads are rare (manual or on file save).
- The configuration is advisory (model selection, not safety-critical).
- A reader seeing old `:models` with new `:defaults` for one request is harmless.

If stronger atomicity is ever needed, the alternative is:

1. Create a new named ETS table.
2. Populate it with the new data.
3. Rename via `:ets.rename/2` (atomic).
4. Delete the old table.

This can be added later without changing the public API.

---

## 6. Hot-Reload Design

### 6.1 Standalone Config Watcher

`Assistant.Config.Watcher` is a dedicated GenServer that watches `config/config.yaml` for changes. It is separate from `Assistant.Skills.Watcher` (which watches the `skills/` directory for skill hot-reload). Each watcher has a single responsibility and independent lifecycle.

```
config/config.yaml changed
    |
    v
Assistant.Config.Watcher detects :modified event
    |
    v
Debounce (500ms) to coalesce rapid edits
    |
    v
Calls Assistant.Config.Loader.reload()
    |
    v
GenServer reads file, interpolates env vars, parses YAML
    |
    v
Validates against schema rules
    |         |
    v         v
  PASS      FAIL
    |         |
    v         v
  Update    Log warning,
  ETS       keep old config
    |
    v
  Log: "Config reloaded successfully"
```

### 6.2 Watcher Module

```elixir
defmodule Assistant.Config.Watcher do
  @moduledoc """
  FileSystem-based watcher for config/config.yaml.
  Debounces file change events and triggers ConfigLoader.reload/0.
  Separate from Assistant.Skills.Watcher (different directory, different concern).
  """

  use GenServer

  @debounce_ms 500

  def start_link(opts) do
    path = Keyword.fetch!(opts, :path)
    GenServer.start_link(__MODULE__, path, name: __MODULE__)
  end
end
```

**Supervision tree entry:**

```elixir
# In Assistant.Application children list
{Assistant.Config.Watcher, path: "config/config.yaml"}
```

### 6.3 Separation from Skills.Watcher

| Watcher | Watches | Triggers | Reason for separation |
|---------|---------|----------|----------------------|
| `Assistant.Config.Watcher` | `config/config.yaml` | `ConfigLoader.reload/0` | Config is a single file with schema validation; failure keeps old config |
| `Assistant.Skills.Watcher` | `skills/` directory (recursive) | `Registry.reload/0` | Skills are many files with independent loading; failure affects only the changed skill |

Both use the `file_system` dependency but operate independently. A crash in one does not affect the other (`:one_for_one` supervisor strategy).

---

## 7. Orchestrator Model Selection Flow

### 7.1 Default Resolution (no override)

```
Orchestrator needs model for :sub_agent role
    |
    v
ConfigLoader.model_for(:sub_agent)
    |
    v
Look up defaults[:sub_agent] -> :balanced
    |
    v
Find first model in roster where tier == :balanced
  AND :sub_agent in use_cases
    |
    v
Return %Model{id: "google/gemini-2.5-flash-preview-05-20", ...}
```

### 7.2 Override: Prefer a Different Tier

The orchestrator can escalate a sub-agent to a higher-tier model for complex tasks:

```elixir
# Complex task — use primary tier instead of the default balanced
ConfigLoader.model_for(:sub_agent, prefer: :primary)
# => %Model{id: "anthropic/claude-sonnet-4-6", ...}
```

Resolution: `prefer:` replaces the tier from `defaults`. The function still filters by use_case — only models listing `:sub_agent` in their `use_cases` are eligible.

```
ConfigLoader.model_for(:sub_agent, prefer: :primary)
    |
    v
Override tier: :primary (ignores defaults[:sub_agent])
    |
    v
Find first model in roster where tier == :primary
  AND :sub_agent in use_cases
    |
    v
Return %Model{id: "anthropic/claude-sonnet-4-6", ...}
```

### 7.3 Override: Explicit Model by ID

The orchestrator can select a specific model by OpenRouter ID:

```elixir
# Pin to a specific model regardless of tier/defaults
ConfigLoader.model_for(:sub_agent, id: "openai/gpt-4.1-mini")
# => %Model{id: "openai/gpt-4.1-mini", ...}
```

Resolution: `id:` bypasses tier lookup entirely. Returns the matching model from the roster if it exists and lists the use_case, or `nil` if not found.

```
ConfigLoader.model_for(:sub_agent, id: "openai/gpt-4.1-mini")
    |
    v
Find model in roster where id == "openai/gpt-4.1-mini"
  AND :sub_agent in use_cases
    |
    v
Return %Model{id: "openai/gpt-4.1-mini", ...} or nil
```

**Precedence**: `id:` > `prefer:` > `defaults`. If both `id:` and `prefer:` are given, `id:` wins.

### 7.4 Browsing the Roster

The orchestrator can also browse models by tier for decision-making:

```elixir
ConfigLoader.models_by_tier(:primary)
# => [%Model{id: "anthropic/claude-sonnet-4-6", ...}, ...]
```

The config provides the roster; the orchestrator makes the selection.

---

## 8. Boot Sequence

```
Assistant.Application (supervision tree, :one_for_one)
    |
    +-- Assistant.Config.Loader (GenServer)
    |     init/1:
    |       1. Create ETS table :assistant_config
    |       2. Read config/config.yaml
    |       3. Interpolate ${ENV_VAR} patterns
    |       4. Parse YAML (via yaml_elixir)
    |       5. Validate schema
    |       6. Populate ETS
    |       7. If any step fails -> crash (supervisor retries)
    |
    +-- Assistant.Config.Watcher (GenServer)           # standalone, config only
    |     Watches config/config.yaml, debounces, calls Loader.reload/0
    |
    +-- Assistant.Skills.Registry (GenServer)
    |
    +-- Assistant.Skills.Watcher (GenServer)            # separate, skills/ only
    |     Watches skills/ directory, calls Registry.reload/0
    |
    +-- ... (remaining children: Repo, Endpoint, Oban, etc.)
```

**Boot failure behavior:** If `config/config.yaml` is missing, malformed, or references undefined env vars, the `ConfigLoader` crashes on `init/1`. The supervisor will retry with backoff. This is intentional — the assistant cannot operate without a model roster.

---

## 9. Dependencies

### YAML Parser

Use `yaml_elixir` (wraps `:yamerl`):

```elixir
{:yaml_elixir, "~> 2.11"}
```

This should be added to `mix.exs` dependencies.

### FileSystem Watcher

The project already plans to use `file_system` for skill hot-reload. The same dependency serves config watching:

```elixir
{:file_system, "~> 1.0"}
```

---

## 10. Relationship to runtime.exs

The YAML config and `runtime.exs` have distinct, non-overlapping responsibilities:

| Concern | Where | Why |
|---------|-------|-----|
| API keys (OpenRouter, ElevenLabs, Google, HubSpot) | `runtime.exs` | Secrets — never in version control |
| Model roster (IDs, tiers, use cases) | `config/config.yaml` | Human-editable, version-controlled, hot-reloadable |
| Default model assignments | `config/config.yaml` | Operational tuning, config-only changes |
| Voice configuration (model, settings) | `config/config.yaml` | Operational tuning |
| Voice ID | `config/config.yaml` with `${ELEVENLABS_VOICE_ID}` | Varies per deployment |
| Database URL, Phoenix settings | `runtime.exs` | Infrastructure secrets |

`runtime.exs` is the boundary for secrets. `config/config.yaml` is the boundary for operational tuning.

---

## 11. Future Considerations

- **Per-model cost tracking**: The `cost_tier` field is a coarse classification. Future: add `input_cost_per_token` and `output_cost_per_token` fields for budget enforcement.
- **Model health/availability**: Future: track model availability and auto-failover within the same tier.
- **Multiple voice profiles**: Future: the `voice` section could become a list of named profiles selectable per user or channel.
- **YAML schema validation**: Future: use a JSON Schema or NimbleOptions-based validator for compile-time schema checking of the YAML structure.
