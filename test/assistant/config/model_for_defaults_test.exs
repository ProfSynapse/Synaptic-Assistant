defmodule Assistant.Config.ModelForDefaultsTest do
  @moduledoc """
  Integration test: model_for/2 resolves admin-set model defaults via ModelDefaults.

  Uses DataCase (DB access) + a dedicated Config.Loader with temp YAML to verify
  the full path: model_for -> ModelDefaults.default_model_id -> IntegrationSettings.
  """
  use Assistant.DataCase, async: false

  alias Assistant.Config.Loader
  alias Assistant.IntegrationSettings.Cache
  alias Assistant.ModelDefaults

  import Assistant.AccountsFixtures

  @yaml """
  defaults:
    orchestrator: primary

  models:
    - id: "test/primary-model"
      tier: primary
      description: "Default primary model"
      use_cases:
        - orchestrator
      input_modalities:
        - text
        - document
      supports_tools: true
      max_context_tokens: 200000
      cost_tier: high

    - id: "test/admin-override-model"
      tier: fast
      description: "Admin override model"
      use_cases:
        - orchestrator
      input_modalities:
        - text
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

  setup do
    # Detach app-level Loader to avoid conflicts
    if Process.whereis(Loader) && Process.whereis(Assistant.Supervisor) do
      Supervisor.terminate_child(Assistant.Supervisor, Loader)
      Supervisor.delete_child(Assistant.Supervisor, Loader)
    end

    if :ets.whereis(:assistant_config) != :undefined do
      try do
        :ets.delete(:assistant_config)
      rescue
        ArgumentError -> :ok
      end
    end

    # Override legacy defaults path so file-backed defaults don't interfere
    previous_path = Application.get_env(:assistant, :model_defaults_path)
    Application.put_env(:assistant, :model_defaults_path, "/tmp/nonexistent_model_defaults.json")

    # Fresh ETS cache from this test's sandbox DB
    Cache.invalidate_all()
    Cache.warm()

    tmp_path =
      Path.join(
        System.tmp_dir!(),
        "model_for_defaults_#{System.unique_integer([:positive])}.yaml"
      )

    File.write!(tmp_path, @yaml)

    on_exit(fn ->
      File.rm(tmp_path)

      if previous_path do
        Application.put_env(:assistant, :model_defaults_path, previous_path)
      else
        Application.delete_env(:assistant, :model_defaults_path)
      end

      case Process.whereis(Loader) do
        nil -> :ok
        pid -> if Process.alive?(pid), do: GenServer.stop(pid, :normal, 1_000)
      end

      Process.sleep(10)

      if :ets.whereis(:assistant_config) != :undefined do
        try do
          :ets.delete(:assistant_config)
        rescue
          ArgumentError -> :ok
        end
      end

      if Process.whereis(Assistant.Supervisor) do
        Supervisor.start_child(Assistant.Supervisor, Assistant.Config.Loader)
      end
    end)

    %{config_path: tmp_path}
  end

  test "model_for resolves admin-set default model from IntegrationSettings", %{
    config_path: path
  } do
    {:ok, _pid} = Loader.start_link(path: path)

    # Without any override, model_for(:orchestrator) resolves via tier default (primary)
    model = Loader.model_for(:orchestrator)
    assert model.id == "test/primary-model"

    # Admin sets a global model default for orchestrator
    admin = admin_settings_user_fixture(%{email: unique_settings_user_email()})

    assert :ok =
             ModelDefaults.save_defaults(admin, %{"orchestrator" => "test/admin-override-model"})

    # Allow PubSub invalidation, then re-warm cache
    Process.sleep(10)
    Cache.warm()

    # Now model_for should resolve to the admin-set override
    model_with_override = Loader.model_for(:orchestrator, settings_user: admin)
    assert model_with_override.id == "test/admin-override-model"
  end

  test "model_for falls back to tier default when admin override model not in use_cases", %{
    config_path: path
  } do
    {:ok, _pid} = Loader.start_link(path: path)

    admin = admin_settings_user_fixture(%{email: unique_settings_user_email()})

    # Set a model ID that exists but doesn't have :sentinel as a use_case
    assert :ok =
             ModelDefaults.save_defaults(admin, %{"sentinel" => "test/admin-override-model"})

    Process.sleep(10)
    Cache.warm()

    # model_for(:sentinel) should return nil because neither model has sentinel in use_cases,
    # and the override model doesn't match the use_case check
    model = Loader.model_for(:sentinel, settings_user: admin)
    assert model == nil
  end
end
