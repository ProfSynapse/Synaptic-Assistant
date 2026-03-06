defmodule Assistant.ModelDefaultsTest do
  @moduledoc """
  Tests for ModelDefaults authorization, mode, and effective defaults merging.
  """
  use Assistant.DataCase, async: false

  alias Assistant.ModelDefaults
  alias Assistant.IntegrationSettings.Cache

  import Assistant.AccountsFixtures

  # In sandbox mode, PubSub broadcasts cause the Cache GenServer to invalidate
  # ETS entries (instead of re-warming from DB). After saving global defaults,
  # we must re-warm the cache so subsequent reads find the values.
  defp save_and_warm_cache(args) do
    result = apply(ModelDefaults, :save_defaults, args)
    # Allow PubSub invalidation message to be processed first
    Process.sleep(10)
    Cache.warm()
    result
  end

  # Override the legacy defaults path so file-backed defaults don't interfere.
  # Also warm the ETS cache from the fresh sandbox DB so stale entries from
  # prior tests don't leak through IntegrationSettings.get/1.
  setup do
    previous_path = Application.get_env(:assistant, :model_defaults_path)
    Application.put_env(:assistant, :model_defaults_path, "/tmp/nonexistent_model_defaults.json")

    # Clear all ETS entries from prior tests, then re-warm from this test's
    # fresh sandbox DB (which has no integration_settings rows yet).
    Cache.invalidate_all()
    Cache.warm()

    on_exit(fn ->
      if previous_path do
        Application.put_env(:assistant, :model_defaults_path, previous_path)
      else
        Application.delete_env(:assistant, :model_defaults_path)
      end
    end)

    :ok
  end

  describe "mode/1" do
    test "returns :global for admin" do
      admin = admin_settings_user_fixture()
      assert ModelDefaults.mode(admin) == :global
    end

    test "returns :readonly for non-admin" do
      user = settings_user_fixture()
      assert ModelDefaults.mode(user) == :readonly
    end

    test "returns :readonly for nil" do
      assert ModelDefaults.mode(nil) == :readonly
    end
  end

  describe "editable?/1" do
    test "returns true for admin" do
      admin = admin_settings_user_fixture()
      assert ModelDefaults.editable?(admin) == true
    end

    test "returns false for non-admin" do
      user = settings_user_fixture()
      assert ModelDefaults.editable?(user) == false
    end

    test "returns false for nil" do
      assert ModelDefaults.editable?(nil) == false
    end
  end

  describe "save_defaults/2" do
    test "returns :not_authorized for non-admin" do
      user = settings_user_fixture()

      assert ModelDefaults.save_defaults(user, %{"orchestrator" => "some/model"}) ==
               {:error, :not_authorized}
    end

    test "succeeds for admin" do
      admin = admin_settings_user_fixture()
      assert ModelDefaults.save_defaults(admin, %{"orchestrator" => "openai/gpt-5-mini"}) == :ok
    end

    test "saved global defaults are retrievable" do
      admin = admin_settings_user_fixture()
      :ok = save_and_warm_cache([admin, %{"orchestrator" => "openai/gpt-5-mini"}])

      defaults = ModelDefaults.global_defaults()
      assert Map.get(defaults, "orchestrator") == "openai/gpt-5-mini"
    end

    test "empty string value clears the default" do
      admin = admin_settings_user_fixture()
      :ok = save_and_warm_cache([admin, %{"orchestrator" => "openai/gpt-5-mini"}])
      :ok = save_and_warm_cache([admin, %{"orchestrator" => ""}])

      defaults = ModelDefaults.global_defaults()
      refute Map.has_key?(defaults, "orchestrator")
    end

    test "unknown role keys are silently ignored" do
      admin = admin_settings_user_fixture()

      :ok =
        save_and_warm_cache([
          admin,
          %{"unknown_role" => "some/model", "orchestrator" => "openai/gpt-5-mini"}
        ])

      defaults = ModelDefaults.global_defaults()
      assert Map.get(defaults, "orchestrator") == "openai/gpt-5-mini"
      refute Map.has_key?(defaults, "unknown_role")
    end
  end

  describe "save_defaults/3 (actor, target, params)" do
    test "admin can set defaults for non-admin user" do
      admin = admin_settings_user_fixture()
      target = settings_user_fixture()

      assert ModelDefaults.save_defaults(admin, target, %{"orchestrator" => "openai/gpt-5-mini"}) ==
               :ok

      user_defaults = ModelDefaults.user_defaults(Repo.reload!(target))
      assert Map.get(user_defaults, "orchestrator") == "openai/gpt-5-mini"
    end

    test "non-admin cannot set defaults for another user" do
      actor = settings_user_fixture()
      target = settings_user_fixture()

      assert ModelDefaults.save_defaults(actor, target, %{"orchestrator" => "some/model"}) ==
               {:error, :not_authorized}
    end

    test "self-edit delegates to save_defaults/2" do
      admin = admin_settings_user_fixture()

      # Admin editing themselves goes through save_defaults/2 (global path)
      assert ModelDefaults.save_defaults(admin, admin, %{"orchestrator" => "openai/gpt-5-mini"}) ==
               :ok
    end
  end

  describe "effective_defaults/1" do
    test "admin sees only global defaults (no user overrides)" do
      admin = admin_settings_user_fixture()
      :ok = save_and_warm_cache([admin, %{"orchestrator" => "openai/gpt-5-mini"}])

      effective = ModelDefaults.effective_defaults(admin)
      assert Map.get(effective, "orchestrator") == "openai/gpt-5-mini"
    end

    test "non-admin sees global merged with user overrides" do
      admin = admin_settings_user_fixture()
      target = settings_user_fixture()

      # Set global default
      :ok = save_and_warm_cache([admin, %{"orchestrator" => "openai/gpt-5-mini"}])

      # Set user override for a different role (user overrides go to settings_users, no cache issue)
      :ok =
        ModelDefaults.save_defaults(admin, target, %{"sub_agent" => "anthropic/claude-sonnet-4.6"})

      effective = ModelDefaults.effective_defaults(Repo.reload!(target))

      # Global default visible
      assert Map.get(effective, "orchestrator") == "openai/gpt-5-mini"
      # User override visible
      assert Map.get(effective, "sub_agent") == "anthropic/claude-sonnet-4.6"
    end

    test "user override takes precedence over global for same role" do
      admin = admin_settings_user_fixture()
      target = settings_user_fixture()

      :ok = save_and_warm_cache([admin, %{"orchestrator" => "openai/gpt-5-mini"}])

      :ok =
        ModelDefaults.save_defaults(admin, target, %{
          "orchestrator" => "anthropic/claude-sonnet-4.6"
        })

      effective = ModelDefaults.effective_defaults(Repo.reload!(target))
      assert Map.get(effective, "orchestrator") == "anthropic/claude-sonnet-4.6"
    end

    test "nil returns global defaults only" do
      admin = admin_settings_user_fixture()
      :ok = save_and_warm_cache([admin, %{"orchestrator_fallback" => "openai/gpt-5-mini"}])

      effective = ModelDefaults.effective_defaults(nil)
      assert Map.get(effective, "orchestrator_fallback") == "openai/gpt-5-mini"
    end
  end

  describe "default_model_id/2" do
    test "returns nil for unknown role" do
      assert ModelDefaults.default_model_id(:nonexistent_role) == nil
    end

    test "returns nil when no default is set" do
      # With legacy defaults path overridden to nonexistent file,
      # no DB defaults set, should return nil for any valid role
      assert ModelDefaults.default_model_id(:orchestrator) == nil
      assert ModelDefaults.default_model_id(:orchestrator_fallback) == nil
    end

    test "returns the global default when set" do
      admin = admin_settings_user_fixture()
      :ok = save_and_warm_cache([admin, %{"orchestrator" => "openai/gpt-5-mini"}])

      assert ModelDefaults.default_model_id(:orchestrator) == "openai/gpt-5-mini"
    end
  end
end
