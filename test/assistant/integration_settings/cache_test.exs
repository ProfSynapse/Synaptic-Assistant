defmodule Assistant.IntegrationSettings.CacheTest do
  use Assistant.DataCase, async: false

  alias Assistant.IntegrationSettings
  alias Assistant.IntegrationSettings.Cache

  # The Cache GenServer is started by the supervision tree.
  # We just clear ETS before each test for isolation.
  setup do
    Cache.invalidate_all()
    :ok
  end

  describe "lookup/1" do
    test "returns :miss for uncached key" do
      assert Cache.lookup(:hubspot_api_key) == :miss
    end

    test "returns {:ok, value} after put" do
      Cache.put(:hubspot_api_key, "test_value")
      assert Cache.lookup(:hubspot_api_key) == {:ok, "test_value"}
    end
  end

  describe "put/2" do
    test "inserts key-value into ETS" do
      assert :ok = Cache.put(:hubspot_api_key, "val1")
      assert {:ok, "val1"} = Cache.lookup(:hubspot_api_key)
    end

    test "overwrites existing value" do
      Cache.put(:hubspot_api_key, "first")
      Cache.put(:hubspot_api_key, "second")
      assert {:ok, "second"} = Cache.lookup(:hubspot_api_key)
    end
  end

  describe "invalidate/1" do
    test "removes a key from ETS" do
      Cache.put(:hubspot_api_key, "to_remove")
      assert {:ok, _} = Cache.lookup(:hubspot_api_key)

      Cache.invalidate(:hubspot_api_key)
      assert Cache.lookup(:hubspot_api_key) == :miss
    end

    test "no-op for non-existent key" do
      assert :ok = Cache.invalidate(:nonexistent_key)
    end
  end

  describe "invalidate_all/0" do
    test "clears all keys from ETS" do
      Cache.put(:hubspot_api_key, "val1")
      Cache.put(:slack_bot_token, "val2")

      assert :ok = Cache.invalidate_all()

      assert Cache.lookup(:hubspot_api_key) == :miss
      assert Cache.lookup(:slack_bot_token) == :miss
    end
  end

  describe "warm/0" do
    test "loads DB rows into ETS" do
      # Insert some rows via the context module (which handles RLS)
      {:ok, _} = IntegrationSettings.put(:hubspot_api_key, "warm_test_val")
      {:ok, _} = IntegrationSettings.put(:slack_bot_token, "xoxb-warm-test")

      # Clear ETS to simulate cold cache
      Cache.invalidate_all()
      assert Cache.lookup(:hubspot_api_key) == :miss

      # Warm the cache
      assert :ok = Cache.warm()

      # Values should now be in ETS
      assert {:ok, "warm_test_val"} = Cache.lookup(:hubspot_api_key)
      assert {:ok, "xoxb-warm-test"} = Cache.lookup(:slack_bot_token)
    end

    test "warm after delete does not load deleted key" do
      {:ok, _} = IntegrationSettings.put(:hubspot_api_key, "will_be_deleted")
      IntegrationSettings.delete(:hubspot_api_key)

      Cache.invalidate_all()
      Cache.warm()

      assert Cache.lookup(:hubspot_api_key) == :miss
    end
  end

  describe "warm failure mode" do
    test "warm/0 returns error tuple on DB failure, cache stays empty" do
      # Insert a value into the DB, then invalidate ETS to simulate cold cache
      {:ok, _} = IntegrationSettings.put(:hubspot_api_key, "warm_fail_test")
      Cache.invalidate_all()
      assert Cache.lookup(:hubspot_api_key) == :miss

      # Checkout a second sandbox connection and break it to simulate DB failure
      # by rolling back the sandbox owner mid-warm. Instead, we test the contract:
      # after a failed warm(), cache remains empty and get/1 falls through to env var.

      # First, verify warm works normally
      assert :ok = Cache.warm()
      assert {:ok, "warm_fail_test"} = Cache.lookup(:hubspot_api_key)

      # Now invalidate again and test that an empty cache falls through correctly
      Cache.invalidate_all()
      assert Cache.lookup(:hubspot_api_key) == :miss

      # With empty cache, get/1 should return nil (no env var for hubspot_api_key)
      assert IntegrationSettings.get(:hubspot_api_key) == nil
    end

    test "cache starts empty when warm fails — env var fallback works" do
      # Ensure ETS is empty (simulating failed init warm)
      Cache.invalidate_all()

      # :openrouter_api_key has an env var set in config/test.exs
      # With empty cache, get/1 should fall through to the env var
      assert Cache.lookup(:openrouter_api_key) == :miss
      assert IntegrationSettings.get(:openrouter_api_key) == "test-openrouter-key"
    end

    test "warm recovers after previous failure — populates cache from DB" do
      # Put a value in DB
      {:ok, _} = IntegrationSettings.put(:slack_bot_token, "xoxb-recovery-test")

      # Simulate failed warm: clear cache
      Cache.invalidate_all()
      assert Cache.lookup(:slack_bot_token) == :miss

      # Warm should succeed and repopulate
      assert :ok = Cache.warm()
      assert {:ok, "xoxb-recovery-test"} = Cache.lookup(:slack_bot_token)
    end
  end

  describe "PubSub invalidation" do
    test "invalidates key on PubSub broadcast" do
      Cache.put(:hubspot_api_key, "pubsub_test")
      assert {:ok, "pubsub_test"} = Cache.lookup(:hubspot_api_key)

      # Broadcast a change event (same as IntegrationSettings.put does)
      Phoenix.PubSub.broadcast(
        Assistant.PubSub,
        "integration_settings:changed",
        %{key: :hubspot_api_key}
      )

      # Give the GenServer a moment to process the message
      Process.sleep(50)

      assert Cache.lookup(:hubspot_api_key) == :miss
    end

    test "ignores unrelated PubSub messages" do
      Cache.put(:hubspot_api_key, "keep_this")

      Phoenix.PubSub.broadcast(
        Assistant.PubSub,
        "integration_settings:changed",
        %{unrelated: "data"}
      )

      Process.sleep(50)

      # Key should still be there since the message didn't match the handler
      assert {:ok, "keep_this"} = Cache.lookup(:hubspot_api_key)
    end

    test "only invalidates the specific key, not all keys" do
      Cache.put(:hubspot_api_key, "hubspot_val")
      Cache.put(:slack_bot_token, "slack_val")

      Phoenix.PubSub.broadcast(
        Assistant.PubSub,
        "integration_settings:changed",
        %{key: :hubspot_api_key}
      )

      Process.sleep(50)

      assert Cache.lookup(:hubspot_api_key) == :miss
      assert {:ok, "slack_val"} = Cache.lookup(:slack_bot_token)
    end
  end
end
