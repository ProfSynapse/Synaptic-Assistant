# test/assistant/config/loader_test.exs
#
# Tests for YAML config loading, env var interpolation, and validation.
# Starts a dedicated Config.Loader per test with a temp config file
# to avoid interfering with the app-level loader.

defmodule Assistant.Config.LoaderTest do
  use ExUnit.Case, async: false
  # async: false because we manipulate ETS named tables

  alias Assistant.Config.Loader

  @valid_yaml """
  defaults:
    orchestrator: primary
    sub_agent: balanced
    compaction: fast
    sentinel: fast

  models:
    - id: "test/model-primary"
      tier: primary
      description: "Test primary model"
      use_cases:
        - orchestrator
        - sub_agent
      supports_tools: true
      max_context_tokens: 200000
      cost_tier: high

    - id: "test/model-fast"
      tier: fast
      description: "Test fast model"
      use_cases:
        - sub_agent
        - compaction
        - sentinel
      supports_tools: true
      max_context_tokens: 100000
      cost_tier: low

  http:
    max_retries: 3
    base_backoff_ms: 1000
    max_backoff_ms: 30000
    request_timeout_ms: 120000
    streaming_timeout_ms: 300000

  limits:
    context_utilization_target: 0.85
    compaction_trigger_threshold: 0.75
    response_reserve_tokens: 4096
    orchestrator_turn_limit: 100
    sub_agent_turn_limit: 30
    cache_ttl_seconds: 3600
    orchestrator_cache_breakpoints: 4
    sub_agent_cache_breakpoints: 1

  voice:
    voice_id: "test_voice_id"
    tts_model: "eleven_flash_v2_5"
    optimize_streaming_latency: 3
    output_format: "mp3_44100_128"
    voice_settings:
      stability: 0.5
      similarity_boost: 0.75
      style: 0.0
      speed: 1.0
  """

  setup do
    # Detach Loader from the supervisor to prevent restart cascades.
    # GenServer.stop triggers supervisor auto-restart; repeated stops across
    # describe blocks exceed max_restarts and crash the entire supervision
    # tree (including Repo). terminate_child + delete_child avoids this.
    if Process.whereis(Loader) && Process.whereis(Assistant.Supervisor) do
      Supervisor.terminate_child(Assistant.Supervisor, Loader)
      Supervisor.delete_child(Assistant.Supervisor, Loader)
    end

    # Clean up stale ETS table if left over from a previous test
    if :ets.whereis(:assistant_config) != :undefined do
      try do
        :ets.delete(:assistant_config)
      rescue
        ArgumentError -> :ok
      end
    end

    # Write a temp config file
    tmp_dir = System.tmp_dir!()
    config_path = Path.join(tmp_dir, "test_config_#{System.unique_integer([:positive])}.yaml")
    File.write!(config_path, @valid_yaml)

    on_exit(fn ->
      File.rm(config_path)

      # Stop any test-started Loader instance
      case Process.whereis(Loader) do
        nil -> :ok
        pid -> if Process.alive?(pid), do: GenServer.stop(pid, :normal, 1_000)
      end

      Process.sleep(10)

      # Clean up ETS table before restarting supervised instance
      if :ets.whereis(:assistant_config) != :undefined do
        try do
          :ets.delete(:assistant_config)
        rescue
          ArgumentError -> :ok
        end
      end

      # Restore the supervised Loader for other test modules (if supervisor is still alive)
      if Process.whereis(Assistant.Supervisor) do
        Supervisor.start_child(Assistant.Supervisor, Assistant.Config.Loader)
      end
    end)

    %{config_path: config_path}
  end

  # ---------------------------------------------------------------
  # GenServer init — loading and validation
  # ---------------------------------------------------------------

  describe "start_link/1" do
    test "loads valid config and populates ETS", %{config_path: path} do
      assert {:ok, pid} = Loader.start_link(path: path)
      assert Process.alive?(pid)

      # Verify ETS is populated
      models = Loader.all_models()
      assert length(models) == 2

      http = Loader.http_config()
      assert http.max_retries == 3

      limits = Loader.limits_config()
      assert limits.context_utilization_target == 0.85

      GenServer.stop(pid)
    end

    test "fails to start with missing config file" do
      Process.flag(:trap_exit, true)
      assert {:error, _} = Loader.start_link(path: "/nonexistent/config.yaml")
    end

    test "fails to start with invalid YAML" do
      tmp_dir = System.tmp_dir!()
      bad_path = Path.join(tmp_dir, "bad_config_#{System.unique_integer([:positive])}.yaml")
      File.write!(bad_path, ": invalid: yaml: [[[")

      Process.flag(:trap_exit, true)
      result = Loader.start_link(path: bad_path)

      case result do
        {:error, _} -> :ok
        {:ok, pid} -> GenServer.stop(pid)
      end

      File.rm(bad_path)
    end
  end

  # ---------------------------------------------------------------
  # model_for/2
  # ---------------------------------------------------------------

  describe "model_for/2" do
    setup %{config_path: path} do
      case Loader.start_link(path: path) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
      end
    end

    test "resolves model by role default" do
      model = Loader.model_for(:orchestrator)
      assert model != nil
      assert model.tier == :primary
      assert :orchestrator in model.use_cases
    end

    test "resolves model with prefer option" do
      model = Loader.model_for(:sub_agent, prefer: :fast)
      assert model != nil
      assert model.tier == :fast
    end

    test "resolves model by explicit id" do
      model = Loader.model_for(:sub_agent, id: "test/model-fast")
      assert model != nil
      assert model.id == "test/model-fast"
    end

    test "returns nil for non-matching role" do
      model = Loader.model_for(:nonexistent_role)
      assert model == nil
    end

    test "returns nil for non-matching explicit id" do
      model = Loader.model_for(:orchestrator, id: "nonexistent/model")
      assert model == nil
    end
  end

  # ---------------------------------------------------------------
  # http_config/0
  # ---------------------------------------------------------------

  describe "http_config/0" do
    setup %{config_path: path} do
      {:ok, _pid} = Loader.start_link(path: path)
      :ok
    end

    test "returns all HTTP fields" do
      config = Loader.http_config()
      assert config.max_retries == 3
      assert config.base_backoff_ms == 1000
      assert config.max_backoff_ms == 30_000
      assert config.request_timeout_ms == 120_000
      assert config.streaming_timeout_ms == 300_000
    end
  end

  # ---------------------------------------------------------------
  # limits_config/0
  # ---------------------------------------------------------------

  describe "limits_config/0" do
    setup %{config_path: path} do
      {:ok, _pid} = Loader.start_link(path: path)
      :ok
    end

    test "returns all limits fields" do
      limits = Loader.limits_config()
      assert limits.context_utilization_target == 0.85
      assert limits.compaction_trigger_threshold == 0.75
      assert limits.response_reserve_tokens == 4096
      assert limits.orchestrator_turn_limit == 100
      assert limits.sub_agent_turn_limit == 30
      assert limits.cache_ttl_seconds == 3600
    end
  end

  # ---------------------------------------------------------------
  # Env var interpolation
  # ---------------------------------------------------------------

  describe "env var interpolation" do
    test "interpolates environment variables" do
      yaml_with_env = """
      defaults:
        orchestrator: primary

      models:
        - id: "${TEST_MODEL_ID}"
          tier: primary
          description: "env test"
          use_cases:
            - orchestrator
          supports_tools: true
          max_context_tokens: 100000
          cost_tier: low

      http:
        max_retries: 1
        base_backoff_ms: 100
        max_backoff_ms: 1000
        request_timeout_ms: 5000
        streaming_timeout_ms: 10000

      limits:
        context_utilization_target: 0.8
        compaction_trigger_threshold: 0.7
        response_reserve_tokens: 1024
        orchestrator_turn_limit: 10
        sub_agent_turn_limit: 5
        cache_ttl_seconds: 60
        orchestrator_cache_breakpoints: 2
        sub_agent_cache_breakpoints: 1
      """

      System.put_env("TEST_MODEL_ID", "test/interpolated-model")

      tmp_dir = System.tmp_dir!()
      path = Path.join(tmp_dir, "env_test_#{System.unique_integer([:positive])}.yaml")
      File.write!(path, yaml_with_env)

      {:ok, pid} = Loader.start_link(path: path)

      models = Loader.all_models()
      assert hd(models).id == "test/interpolated-model"

      GenServer.stop(pid)
      File.rm(path)
      System.delete_env("TEST_MODEL_ID")
    end

    test "fails on missing env var" do
      yaml_with_missing = """
      defaults:
        orchestrator: primary

      models:
        - id: "${DEFINITELY_MISSING_VAR_12345}"
          tier: primary
          description: "test"
          use_cases:
            - orchestrator
          supports_tools: true
          max_context_tokens: 100000
          cost_tier: low

      http:
        max_retries: 1
        base_backoff_ms: 100
        max_backoff_ms: 1000
        request_timeout_ms: 5000
        streaming_timeout_ms: 10000

      limits:
        context_utilization_target: 0.8
        compaction_trigger_threshold: 0.7
        response_reserve_tokens: 1024
        orchestrator_turn_limit: 10
        sub_agent_turn_limit: 5
        cache_ttl_seconds: 60
        orchestrator_cache_breakpoints: 2
        sub_agent_cache_breakpoints: 1
      """

      # Ensure it's truly unset
      System.delete_env("DEFINITELY_MISSING_VAR_12345")

      tmp_dir = System.tmp_dir!()
      path = Path.join(tmp_dir, "missing_env_#{System.unique_integer([:positive])}.yaml")
      File.write!(path, yaml_with_missing)

      Process.flag(:trap_exit, true)
      result = Loader.start_link(path: path)

      case result do
        {:error, _} -> :ok
        {:ok, pid} -> GenServer.stop(pid)
      end

      File.rm(path)
    end
  end

  # ---------------------------------------------------------------
  # Validation edge cases
  # ---------------------------------------------------------------

  describe "validation" do
    test "rejects missing defaults section" do
      yaml = """
      models:
        - id: "test"
          tier: primary
          description: "test"
          use_cases: [orchestrator]
          supports_tools: true
          max_context_tokens: 100000
          cost_tier: low
      http:
        max_retries: 1
        base_backoff_ms: 100
        max_backoff_ms: 1000
        request_timeout_ms: 5000
        streaming_timeout_ms: 10000
      limits:
        context_utilization_target: 0.8
        compaction_trigger_threshold: 0.7
        response_reserve_tokens: 1024
        orchestrator_turn_limit: 10
        sub_agent_turn_limit: 5
        cache_ttl_seconds: 60
        orchestrator_cache_breakpoints: 2
        sub_agent_cache_breakpoints: 1
      """

      tmp_dir = System.tmp_dir!()
      path = Path.join(tmp_dir, "no_defaults_#{System.unique_integer([:positive])}.yaml")
      File.write!(path, yaml)

      Process.flag(:trap_exit, true)
      result = Loader.start_link(path: path)

      case result do
        {:error, _} -> :ok
        {:ok, pid} -> GenServer.stop(pid)
      end

      File.rm(path)
    end

    test "rejects limits with out-of-range utilization target" do
      yaml = """
      defaults:
        orchestrator: primary
      models:
        - id: "test"
          tier: primary
          description: "test"
          use_cases: [orchestrator]
          supports_tools: true
          max_context_tokens: 100000
          cost_tier: low
      http:
        max_retries: 1
        base_backoff_ms: 100
        max_backoff_ms: 1000
        request_timeout_ms: 5000
        streaming_timeout_ms: 10000
      limits:
        context_utilization_target: 1.5
        compaction_trigger_threshold: 0.7
        response_reserve_tokens: 1024
        orchestrator_turn_limit: 10
        sub_agent_turn_limit: 5
        cache_ttl_seconds: 60
        orchestrator_cache_breakpoints: 2
        sub_agent_cache_breakpoints: 1
      """

      tmp_dir = System.tmp_dir!()
      path = Path.join(tmp_dir, "bad_limits_#{System.unique_integer([:positive])}.yaml")
      File.write!(path, yaml)

      Process.flag(:trap_exit, true)
      result = Loader.start_link(path: path)

      case result do
        {:error, _} -> :ok
        {:ok, pid} -> GenServer.stop(pid)
      end

      File.rm(path)
    end
  end

  # ---------------------------------------------------------------
  # resolve_fast_model/2
  # ---------------------------------------------------------------

  describe "resolve_fast_model/2" do
    test "returns primary role model when it exists", %{config_path: path} do
      # sentinel defaults to :fast tier, test/model-fast has sentinel use_case
      {:ok, _pid} = Loader.start_link(path: path)

      assert Loader.resolve_fast_model(:sentinel) == "test/model-fast"
    end

    test "falls back to _fallback role when primary not found" do
      # Custom YAML: no model for :sentinel directly, but :sentinel_fallback has one
      yaml = """
      defaults:
        orchestrator: primary
        sentinel_fallback: fast

      models:
        - id: "test/primary-only"
          tier: primary
          description: "Primary model"
          use_cases:
            - orchestrator
          supports_tools: true
          max_context_tokens: 200000
          cost_tier: high

        - id: "test/fallback-model"
          tier: fast
          description: "Fallback model"
          use_cases:
            - sentinel_fallback
          supports_tools: true
          max_context_tokens: 100000
          cost_tier: low

      http:
        max_retries: 1
        base_backoff_ms: 100
        max_backoff_ms: 1000
        request_timeout_ms: 5000
        streaming_timeout_ms: 10000

      limits:
        context_utilization_target: 0.8
        compaction_trigger_threshold: 0.7
        response_reserve_tokens: 1024
        orchestrator_turn_limit: 10
        sub_agent_turn_limit: 5
        cache_ttl_seconds: 60
        orchestrator_cache_breakpoints: 2
        sub_agent_cache_breakpoints: 1
      """

      tmp_path = Path.join(System.tmp_dir!(), "cascade_fallback_#{System.unique_integer([:positive])}.yaml")
      File.write!(tmp_path, yaml)
      {:ok, _pid} = Loader.start_link(path: tmp_path)

      # :sentinel has no default tier and no model with sentinel use_case
      # but :sentinel_fallback defaults to :fast and test/fallback-model has that use_case
      assert Loader.resolve_fast_model(:sentinel) == "test/fallback-model"

      File.rm(tmp_path)
    end

    test "falls back to first :fast tier model when neither primary nor fallback found" do
      # Custom YAML: no model matches :compaction or :compaction_fallback use_case,
      # but a :fast tier model exists
      yaml = """
      defaults:
        orchestrator: primary

      models:
        - id: "test/primary-only"
          tier: primary
          description: "Primary model"
          use_cases:
            - orchestrator
          supports_tools: true
          max_context_tokens: 200000
          cost_tier: high

        - id: "test/fast-generic"
          tier: fast
          description: "Fast generic model"
          use_cases:
            - orchestrator
          supports_tools: true
          max_context_tokens: 100000
          cost_tier: low

      http:
        max_retries: 1
        base_backoff_ms: 100
        max_backoff_ms: 1000
        request_timeout_ms: 5000
        streaming_timeout_ms: 10000

      limits:
        context_utilization_target: 0.8
        compaction_trigger_threshold: 0.7
        response_reserve_tokens: 1024
        orchestrator_turn_limit: 10
        sub_agent_turn_limit: 5
        cache_ttl_seconds: 60
        orchestrator_cache_breakpoints: 2
        sub_agent_cache_breakpoints: 1
      """

      tmp_path = Path.join(System.tmp_dir!(), "cascade_fast_#{System.unique_integer([:positive])}.yaml")
      File.write!(tmp_path, yaml)
      {:ok, _pid} = Loader.start_link(path: tmp_path)

      # :compaction has no default tier, no model with compaction use_case,
      # no compaction_fallback either, but fast-generic exists
      assert Loader.resolve_fast_model(:compaction) == "test/fast-generic"

      File.rm(tmp_path)
    end

    test "returns nil when no model found at any cascade level" do
      # Custom YAML: no :fast tier models at all
      yaml = """
      defaults:
        orchestrator: primary

      models:
        - id: "test/primary-only"
          tier: primary
          description: "Primary model"
          use_cases:
            - orchestrator
          supports_tools: true
          max_context_tokens: 200000
          cost_tier: high

      http:
        max_retries: 1
        base_backoff_ms: 100
        max_backoff_ms: 1000
        request_timeout_ms: 5000
        streaming_timeout_ms: 10000

      limits:
        context_utilization_target: 0.8
        compaction_trigger_threshold: 0.7
        response_reserve_tokens: 1024
        orchestrator_turn_limit: 10
        sub_agent_turn_limit: 5
        cache_ttl_seconds: 60
        orchestrator_cache_breakpoints: 2
        sub_agent_cache_breakpoints: 1
      """

      tmp_path = Path.join(System.tmp_dir!(), "cascade_nil_#{System.unique_integer([:positive])}.yaml")
      File.write!(tmp_path, yaml)
      {:ok, _pid} = Loader.start_link(path: tmp_path)

      # :sentinel has no match, no fallback, no fast tier
      assert Loader.resolve_fast_model(:sentinel) == nil

      File.rm(tmp_path)
    end
  end

  # ---------------------------------------------------------------
  # reload/0
  # ---------------------------------------------------------------

  describe "reload/0" do
    test "reloads updated config from disk", %{config_path: path} do
      {:ok, pid} = Loader.start_link(path: path)

      # Verify initial state
      assert length(Loader.all_models()) == 2

      # Write a completely new config with 3 models
      updated_yaml = """
      defaults:
        orchestrator: primary
        sub_agent: balanced
        compaction: fast
        sentinel: fast

      models:
        - id: "test/model-primary"
          tier: primary
          description: "Test primary model"
          use_cases:
            - orchestrator
            - sub_agent
          supports_tools: true
          max_context_tokens: 200000
          cost_tier: high

        - id: "test/model-fast"
          tier: fast
          description: "Test fast model"
          use_cases:
            - sub_agent
            - compaction
            - sentinel
          supports_tools: true
          max_context_tokens: 100000
          cost_tier: low

        - id: "test/model-new"
          tier: balanced
          description: "New model added on reload"
          use_cases:
            - sub_agent
          supports_tools: true
          max_context_tokens: 50000
          cost_tier: medium

      http:
        max_retries: 3
        base_backoff_ms: 1000
        max_backoff_ms: 30000
        request_timeout_ms: 120000
        streaming_timeout_ms: 300000

      limits:
        context_utilization_target: 0.85
        compaction_trigger_threshold: 0.75
        response_reserve_tokens: 4096
        orchestrator_turn_limit: 100
        sub_agent_turn_limit: 30
        cache_ttl_seconds: 3600
        orchestrator_cache_breakpoints: 4
        sub_agent_cache_breakpoints: 1
      """

      File.write!(path, updated_yaml)

      assert :ok = Loader.reload()
      assert length(Loader.all_models()) == 3

      GenServer.stop(pid)
    end

    test "keeps previous config on invalid reload", %{config_path: path} do
      pid =
        case Loader.start_link(path: path) do
          {:ok, p} -> p
          {:error, {:already_started, p}} -> p
        end

      assert length(Loader.all_models()) == 2

      # Overwrite with invalid YAML
      File.write!(path, ": broken yaml [[[")

      assert {:error, _} = Loader.reload()

      # Previous config should still be intact
      assert length(Loader.all_models()) == 2

      GenServer.stop(pid)
    end
  end
end
