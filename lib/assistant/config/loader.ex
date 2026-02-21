# lib/assistant/config/loader.ex — Configuration loader for config.yaml.
#
# ETS-backed GenServer that loads, validates, caches, and hot-reloads the
# model roster, voice configuration, HTTP client settings, and limits from
# config/config.yaml. Public API functions read directly from ETS for
# lock-free concurrent access.
#
# Related files:
#   - config/config.yaml (source of truth for models, voice, HTTP settings)
#   - lib/assistant/config/watcher.ex (file-system watcher, triggers reload)
#   - docs/architecture/config-design.md (design spec)

defmodule Assistant.Config.Loader do
  @moduledoc """
  Loads and serves model roster, voice, HTTP, and limits configuration from config/config.yaml.

  Backed by ETS for fast concurrent reads. The GenServer coordinates reloads
  triggered by `Assistant.Config.Watcher` on file changes.

  ## Public API

  All read functions (`all_models/0`, `model_for/2`, `voice_config/0`,
  `http_config/0`, `limits_config/0`) read directly from ETS — no GenServer
  call overhead.

  ## Boot Behaviour

  If `config/config.yaml` is missing, malformed, or references undefined env
  vars, `init/1` crashes. The supervisor retries with backoff. The assistant
  cannot operate without a model roster.

  ## Hot Reload

  Call `reload/0` (or let `Config.Watcher` call it) to re-read the YAML file.
  If the new file is invalid, the previous configuration is kept and a warning
  is logged.
  """

  use GenServer

  alias Assistant.ModelDefaults

  require Logger

  @ets_table :assistant_config
  @config_path "config/config.yaml"

  # --- Public API (read from ETS, no GenServer call) ---

  @doc """
  Returns the HTTP client configuration as a map.

  Values come from the `http:` section of `config/config.yaml`:

    - `:max_retries` — Maximum retry attempts on transient errors
    - `:base_backoff_ms` — Initial backoff before first retry
    - `:max_backoff_ms` — Cap on backoff duration
    - `:request_timeout_ms` — Per-request timeout for non-streaming requests
    - `:streaming_timeout_ms` — Timeout for streaming (SSE) responses

  Raises if config has not been loaded (GenServer not started).
  """
  @spec http_config() :: %{
          max_retries: pos_integer(),
          base_backoff_ms: pos_integer(),
          max_backoff_ms: pos_integer(),
          request_timeout_ms: pos_integer(),
          streaming_timeout_ms: pos_integer()
        }
  def http_config do
    case :ets.lookup(@ets_table, :http) do
      [{:http, config}] -> config
      [] -> raise "Config not loaded — Assistant.Config.Loader not started"
    end
  end

  @doc """
  Returns all configured models as a list of maps.
  """
  @spec all_models() :: [map()]
  def all_models do
    case :ets.lookup(@ets_table, :models) do
      [{:models, models}] -> models
      [] -> raise "Config not loaded — Assistant.Config.Loader not started"
    end
  end

  @doc """
  Returns the configured default tiers by role.
  """
  @spec defaults() :: map()
  def defaults do
    case :ets.lookup(@ets_table, :defaults) do
      [{:defaults, defaults}] -> defaults
      [] -> raise "Config not loaded — Assistant.Config.Loader not started"
    end
  end

  @doc """
  Returns the model ID for a given use-case role.

  Resolves via defaults: role -> tier -> first matching model.
  Accepts optional overrides:

    - `prefer: :primary` — use the given tier instead of the role's default
    - `id: "provider/model"` — select an explicit model by ID (must exist in roster)

  If `id:` is given, `prefer:` is ignored.
  Returns `nil` if no matching model is found.
  """
  @spec model_for(atom(), keyword()) :: map() | nil
  def model_for(use_case, opts \\ []) do
    [{:models, models}] = :ets.lookup(@ets_table, :models)
    [{:defaults, defaults}] = :ets.lookup(@ets_table, :defaults)

    case Keyword.get(opts, :id) do
      nil ->
        override_id = ModelDefaults.default_model_id(use_case)
        tier = Keyword.get(opts, :prefer) || Map.get(defaults, use_case)

        case find_model_by_id_for_use_case(models, override_id, use_case) do
          nil ->
            Enum.find(models, fn model ->
              model.tier == tier and use_case in model.use_cases
            end)

          model ->
            model
        end

      id ->
        find_model_by_id_for_use_case(models, id, use_case)
    end
  end

  @doc """
  Returns all models matching the given tier.
  """
  @spec models_by_tier(atom()) :: [map()]
  def models_by_tier(tier) do
    [{:models, models}] = :ets.lookup(@ets_table, :models)
    Enum.filter(models, fn model -> model.tier == tier end)
  end

  @doc """
  Returns the voice configuration as a map.
  """
  @spec voice_config() :: map()
  def voice_config do
    case :ets.lookup(@ets_table, :voice) do
      [{:voice, config}] -> config
      [] -> raise "Config not loaded — Assistant.Config.Loader not started"
    end
  end

  @doc """
  Returns the limits configuration as a map.

  Values come from the `limits:` section of `config/config.yaml`:

    - `:context_utilization_target` — Fraction of context window to use (0.0–1.0)
    - `:compaction_trigger_threshold` — Trigger compaction at this utilization
    - `:response_reserve_tokens` — Tokens reserved for model response
    - `:orchestrator_turn_limit` — Max turns per orchestrator conversation
    - `:sub_agent_turn_limit` — Max turns per sub-agent dispatch
    - `:cache_ttl_seconds` — Default cache TTL
    - `:orchestrator_cache_breakpoints` — Max cache breakpoints for orchestrator
    - `:sub_agent_cache_breakpoints` — Max cache breakpoints for sub-agents

  Raises if config has not been loaded (GenServer not started).
  """
  @spec limits_config() :: %{
          context_utilization_target: float(),
          compaction_trigger_threshold: float(),
          response_reserve_tokens: pos_integer(),
          orchestrator_turn_limit: pos_integer(),
          sub_agent_turn_limit: pos_integer(),
          cache_ttl_seconds: pos_integer(),
          orchestrator_cache_breakpoints: pos_integer(),
          sub_agent_cache_breakpoints: pos_integer()
        }
  def limits_config do
    case :ets.lookup(@ets_table, :limits) do
      [{:limits, config}] -> config
      [] -> raise "Config not loaded — Assistant.Config.Loader not started"
    end
  end

  # --- Reload API (goes through GenServer for coordination) ---

  @doc """
  Reloads configuration from disk. Called by Config.Watcher on file change.
  """
  @spec reload() :: :ok | {:error, term()}
  def reload do
    GenServer.call(__MODULE__, :reload)
  end

  # --- GenServer ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    path = Keyword.get(opts, :path, @config_path)
    table = :ets.new(@ets_table, [:named_table, :set, :public, read_concurrency: true])

    case load_and_populate(path, table) do
      :ok ->
        {:ok, %{path: path, table: table}}

      {:error, reason} ->
        {:stop, {:config_load_failed, reason}}
    end
  end

  @impl true
  def handle_call(:reload, _from, %{path: path, table: table} = state) do
    case load_and_populate(path, table) do
      :ok ->
        Logger.info("Config reloaded successfully from #{path}")
        {:reply, :ok, state}

      {:error, reason} ->
        Logger.warning("Config reload failed, keeping previous config",
          reason: inspect(reason)
        )

        {:reply, {:error, reason}, state}
    end
  end

  # --- Internal: YAML Loading & Parsing ---

  defp load_and_populate(path, table) do
    with {:ok, raw} <- File.read(path),
         {:ok, interpolated} <- interpolate_env_vars(raw),
         {:ok, parsed} <- parse_yaml(interpolated),
         {:ok, config} <- validate_and_transform(parsed) do
      :ets.insert(table, [
        {:models, config.models},
        {:defaults, config.defaults},
        {:voice, config.voice},
        {:http, config.http},
        {:limits, config.limits},
        {:loaded_at, DateTime.utc_now()}
      ])

      :ok
    end
  end

  defp interpolate_env_vars(raw) do
    # Matches ${VAR_NAME} (required) and ${VAR_NAME:-default} (optional with default).
    # ${VAR:-} resolves to "" when unset; ${VAR:-fallback} resolves to "fallback" when unset.
    result =
      Regex.replace(~r/\$\{([A-Z_][A-Z0-9_]*)(?::-(.*?))?\}/, raw, fn full_match, var_name, default_part ->
        case System.get_env(var_name) do
          nil ->
            if String.contains?(full_match, ":-") do
              default_part
            else
              throw({:missing_env_var, var_name})
            end

          value ->
            value
        end
      end)

    {:ok, result}
  catch
    {:missing_env_var, var_name} ->
      {:error, {:missing_env_var, var_name}}
  end

  defp parse_yaml(yaml_string) do
    case YamlElixir.read_from_string(yaml_string) do
      {:ok, parsed} -> {:ok, parsed}
      {:error, reason} -> {:error, {:yaml_parse_error, reason}}
    end
  end

  defp find_model_by_id_for_use_case(_models, nil, _use_case), do: nil

  defp find_model_by_id_for_use_case(models, id, use_case) do
    Enum.find(models, fn model ->
      model.id == id and use_case in model.use_cases
    end)
  end

  defp validate_and_transform(parsed) do
    with {:ok, defaults} <- parse_defaults(parsed["defaults"]),
         {:ok, models} <- parse_models(parsed["models"]),
         {:ok, voice} <- parse_voice(parsed["voice"]),
         {:ok, http} <- parse_http(parsed["http"]),
         {:ok, limits} <- parse_limits(parsed["limits"]) do
      {:ok, %{defaults: defaults, models: models, voice: voice, http: http, limits: limits}}
    end
  end

  defp parse_defaults(nil), do: {:error, :missing_defaults_section}

  defp parse_defaults(defaults) when is_map(defaults) do
    atomized =
      Map.new(defaults, fn {key, value} ->
        {String.to_atom(key), String.to_atom(value)}
      end)

    {:ok, atomized}
  end

  defp parse_models(nil), do: {:error, :missing_models_section}

  defp parse_models(models) when is_list(models) do
    parsed =
      Enum.map(models, fn model ->
        %{
          id: model["id"],
          tier: String.to_atom(model["tier"]),
          description: model["description"],
          use_cases: Enum.map(model["use_cases"] || [], &String.to_atom/1),
          supports_tools: model["supports_tools"] || false,
          max_context_tokens: model["max_context_tokens"],
          cost_tier: String.to_atom(model["cost_tier"])
        }
      end)

    {:ok, parsed}
  end

  defp parse_voice(nil), do: {:ok, %{}}

  defp parse_voice(voice) when is_map(voice) do
    voice_settings = voice["voice_settings"] || %{}

    config = %{
      voice_id: voice["voice_id"],
      tts_model: voice["tts_model"],
      optimize_streaming_latency: voice["optimize_streaming_latency"] || 0,
      output_format: voice["output_format"] || "mp3_44100_128",
      voice_settings: %{
        stability: voice_settings["stability"],
        similarity_boost: voice_settings["similarity_boost"],
        style: voice_settings["style"],
        speed: voice_settings["speed"]
      }
    }

    {:ok, config}
  end

  defp parse_http(nil), do: {:error, :missing_http_section}

  defp parse_http(http) when is_map(http) do
    with {:ok, max_retries} <- require_pos_integer(http, "max_retries"),
         {:ok, base_backoff_ms} <- require_pos_integer(http, "base_backoff_ms"),
         {:ok, max_backoff_ms} <- require_pos_integer(http, "max_backoff_ms"),
         {:ok, request_timeout_ms} <- require_pos_integer(http, "request_timeout_ms"),
         {:ok, streaming_timeout_ms} <- require_pos_integer(http, "streaming_timeout_ms") do
      {:ok,
       %{
         max_retries: max_retries,
         base_backoff_ms: base_backoff_ms,
         max_backoff_ms: max_backoff_ms,
         request_timeout_ms: request_timeout_ms,
         streaming_timeout_ms: streaming_timeout_ms
       }}
    end
  end

  defp parse_limits(nil), do: {:error, :missing_limits_section}

  defp parse_limits(limits) when is_map(limits) do
    with {:ok, context_utilization_target} <-
           require_float_in_range(limits, "context_utilization_target", 0.0, 1.0),
         {:ok, compaction_trigger_threshold} <-
           require_float_in_range(limits, "compaction_trigger_threshold", 0.0, 1.0),
         {:ok, response_reserve_tokens} <- require_pos_integer(limits, "response_reserve_tokens"),
         {:ok, orchestrator_turn_limit} <- require_pos_integer(limits, "orchestrator_turn_limit"),
         {:ok, sub_agent_turn_limit} <- require_pos_integer(limits, "sub_agent_turn_limit"),
         {:ok, cache_ttl_seconds} <- require_pos_integer(limits, "cache_ttl_seconds"),
         {:ok, orchestrator_cache_breakpoints} <-
           require_pos_integer(limits, "orchestrator_cache_breakpoints"),
         {:ok, sub_agent_cache_breakpoints} <-
           require_pos_integer(limits, "sub_agent_cache_breakpoints") do
      {:ok,
       %{
         context_utilization_target: context_utilization_target,
         compaction_trigger_threshold: compaction_trigger_threshold,
         response_reserve_tokens: response_reserve_tokens,
         orchestrator_turn_limit: orchestrator_turn_limit,
         sub_agent_turn_limit: sub_agent_turn_limit,
         cache_ttl_seconds: cache_ttl_seconds,
         orchestrator_cache_breakpoints: orchestrator_cache_breakpoints,
         sub_agent_cache_breakpoints: sub_agent_cache_breakpoints
       }}
    end
  end

  defp require_pos_integer(map, key) do
    case map[key] do
      value when is_integer(value) and value > 0 -> {:ok, value}
      nil -> {:error, {:missing_field, key}}
      other -> {:error, {:invalid_field, key, other}}
    end
  end

  defp require_float_in_range(map, key, min, max) do
    case map[key] do
      value when is_number(value) and value >= min and value <= max ->
        {:ok, value / 1}

      nil ->
        {:error, {:missing_field, key}}

      other ->
        {:error, {:invalid_field, key, other}}
    end
  end
end
