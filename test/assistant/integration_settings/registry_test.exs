defmodule Assistant.IntegrationSettings.RegistryTest do
  use ExUnit.Case, async: true

  alias Assistant.IntegrationSettings.Registry

  describe "known_key?/1" do
    test "returns true for a known atom key" do
      assert Registry.known_key?(:openrouter_api_key)
      assert Registry.known_key?(:telegram_bot_token)
      assert Registry.known_key?(:slack_signing_secret)
      assert Registry.known_key?(:discord_application_id)
    end

    test "returns true for a known string key" do
      assert Registry.known_key?("openrouter_api_key")
      assert Registry.known_key?("telegram_bot_token")
    end

    test "returns false for unknown atom key" do
      refute Registry.known_key?(:not_a_real_key)
      refute Registry.known_key?(:admin_password)
    end

    test "returns false for unknown string key" do
      refute Registry.known_key?("not_a_real_key")
      refute Registry.known_key?("")
    end
  end

  describe "definition_for_key/1" do
    test "returns full definition for a known atom key" do
      defn = Registry.definition_for_key(:openrouter_api_key)
      assert defn.key == :openrouter_api_key
      assert defn.secret == true
      assert defn.env == "OPENROUTER_API_KEY"
      assert is_binary(defn.label)
      assert is_binary(defn.help)
      assert defn.group == "ai_providers"
    end

    test "returns full definition for a known string key" do
      defn = Registry.definition_for_key("telegram_bot_token")
      assert defn.key == :telegram_bot_token
      assert defn.group == "telegram"
    end

    test "returns nil for unknown key" do
      assert Registry.definition_for_key(:bogus) == nil
      assert Registry.definition_for_key("bogus") == nil
    end

    test "discord_application_id is not secret" do
      defn = Registry.definition_for_key(:discord_application_id)
      assert defn.secret == false
    end

    test "google_chat_webhook_url is not secret" do
      defn = Registry.definition_for_key(:google_chat_webhook_url)
      assert defn.secret == false
    end

    test "elevenlabs_voice_id is not secret" do
      defn = Registry.definition_for_key(:elevenlabs_voice_id)
      assert defn.secret == false
    end
  end

  describe "all_keys/0" do
    test "returns a non-empty list of key definitions" do
      keys = Registry.all_keys()
      assert is_list(keys)
      assert length(keys) > 0
    end

    test "each key definition has required fields" do
      for key_def <- Registry.all_keys() do
        assert is_atom(key_def.key), "key should be an atom: #{inspect(key_def)}"
        assert is_boolean(key_def.secret), "secret should be boolean: #{inspect(key_def)}"
        assert is_binary(key_def.env), "env should be a string: #{inspect(key_def)}"
        assert is_binary(key_def.label), "label should be a string: #{inspect(key_def)}"
        assert is_binary(key_def.help), "help should be a string: #{inspect(key_def)}"
        assert is_binary(key_def.group), "group should be a string: #{inspect(key_def)}"
      end
    end

    test "no duplicate keys across all groups" do
      keys = Enum.map(Registry.all_keys(), & &1.key)
      assert length(keys) == length(Enum.uniq(keys))
    end
  end

  describe "groups/0" do
    test "returns expected groups" do
      groups = Registry.groups()
      assert is_map(groups)

      expected_groups =
        ~w(ai_providers google_workspace telegram slack discord google_chat hubspot elevenlabs)

      for group_id <- expected_groups do
        assert Map.has_key?(groups, group_id), "missing group: #{group_id}"
        assert is_binary(groups[group_id].label)
        assert is_list(groups[group_id].keys)
        assert length(groups[group_id].keys) > 0
      end
    end
  end

  describe "keys_for_group/1" do
    test "returns keys for a valid group" do
      keys = Registry.keys_for_group("telegram")
      assert is_list(keys)
      assert length(keys) == 3

      key_atoms = Enum.map(keys, & &1.key)
      assert :telegram_bot_token in key_atoms
      assert :telegram_webhook_secret in key_atoms
      assert :telegram_enabled in key_atoms
    end

    test "returns nil for unknown group" do
      assert Registry.keys_for_group("nonexistent") == nil
    end
  end

  describe "env_var_for_key/1" do
    test "maps known keys to env var names" do
      assert Registry.env_var_for_key(:openrouter_api_key) == "OPENROUTER_API_KEY"
      assert Registry.env_var_for_key(:telegram_bot_token) == "TELEGRAM_BOT_TOKEN"
      assert Registry.env_var_for_key(:slack_signing_secret) == "SLACK_SIGNING_SECRET"
    end

    test "returns nil for unknown key" do
      assert Registry.env_var_for_key(:bogus) == nil
    end
  end

  describe "enabled_key?/1" do
    test "returns true for _enabled atom keys" do
      assert Registry.enabled_key?(:telegram_enabled)
      assert Registry.enabled_key?(:slack_enabled)
      assert Registry.enabled_key?(:discord_enabled)
      assert Registry.enabled_key?(:google_workspace_enabled)
      assert Registry.enabled_key?(:google_chat_enabled)
      assert Registry.enabled_key?(:hubspot_enabled)
      assert Registry.enabled_key?(:elevenlabs_enabled)
    end

    test "returns true for _enabled string keys" do
      assert Registry.enabled_key?("telegram_enabled")
      assert Registry.enabled_key?("slack_enabled")
    end

    test "returns false for regular keys" do
      refute Registry.enabled_key?(:openrouter_api_key)
      refute Registry.enabled_key?(:telegram_bot_token)
      refute Registry.enabled_key?("openrouter_api_key")
    end

    test "returns false for unknown keys" do
      refute Registry.enabled_key?(:bogus_enabled)
      refute Registry.enabled_key?("bogus_enabled")
    end
  end

  describe "enabled_key_for_group/1" do
    test "returns the _enabled key atom for known groups" do
      assert Registry.enabled_key_for_group("telegram") == :telegram_enabled
      assert Registry.enabled_key_for_group("slack") == :slack_enabled
      assert Registry.enabled_key_for_group("discord") == :discord_enabled
      assert Registry.enabled_key_for_group("google_workspace") == :google_workspace_enabled
      assert Registry.enabled_key_for_group("google_chat") == :google_chat_enabled
      assert Registry.enabled_key_for_group("hubspot") == :hubspot_enabled
      assert Registry.enabled_key_for_group("elevenlabs") == :elevenlabs_enabled
    end

    test "returns nil for groups without _enabled keys" do
      assert Registry.enabled_key_for_group("ai_providers") == nil
    end

    test "returns nil for unknown groups" do
      assert Registry.enabled_key_for_group("nonexistent") == nil
    end
  end
end
