# test/assistant/encryption/cache_test.exs — Tests for the DEK cache GenServer,
# covering put/get/flush_tenant lifecycle.
#
# Related files:
#   - lib/assistant/encryption/cache.ex (Cache GenServer with ETS-backed DEK cache)

defmodule Assistant.Encryption.CacheTest do
  use ExUnit.Case, async: false

  alias Assistant.Encryption.Cache

  setup do
    # The Cache may already be running under the application supervisor.
    # Stop it and start a fresh instance for isolation.
    case Process.whereis(Cache) do
      nil -> :ok
      pid ->
        GenServer.stop(pid, :normal, 5_000)
        # Wait briefly for the process to fully terminate
        Process.sleep(50)
    end

    {:ok, pid} = Cache.start_link([])

    on_exit(fn ->
      if Process.alive?(pid) do
        GenServer.stop(pid, :normal, 5_000)
      end
    end)

    :ok
  end

  describe "put/3 and get/2" do
    test "stores and retrieves a DEK by tenant and key" do
      Cache.put("tenant_a", "key_1", "dek_value_1")
      # Cast is async — give it a moment to process
      Process.sleep(10)

      assert {:ok, "dek_value_1"} = Cache.get("tenant_a", "key_1")
    end

    test "returns :miss for unknown key" do
      assert :miss = Cache.get("tenant_a", "nonexistent")
    end

    test "returns :miss for unknown tenant" do
      Cache.put("tenant_a", "key_1", "dek_value_1")
      Process.sleep(10)

      assert :miss = Cache.get("tenant_b", "key_1")
    end
  end

  describe "flush_tenant/1" do
    test "removes all cached DEKs for the given tenant" do
      Cache.put("tenant_a", "key_1", "dek_a_1")
      Cache.put("tenant_a", "key_2", "dek_a_2")
      Cache.put("tenant_b", "key_3", "dek_b_1")
      Process.sleep(10)

      # Verify all entries exist before flush
      assert {:ok, "dek_a_1"} = Cache.get("tenant_a", "key_1")
      assert {:ok, "dek_a_2"} = Cache.get("tenant_a", "key_2")
      assert {:ok, "dek_b_1"} = Cache.get("tenant_b", "key_3")

      # Flush tenant_a
      assert :ok = Cache.flush_tenant("tenant_a")

      # tenant_a entries should be gone
      assert :miss = Cache.get("tenant_a", "key_1")
      assert :miss = Cache.get("tenant_a", "key_2")

      # tenant_b entries should remain intact
      assert {:ok, "dek_b_1"} = Cache.get("tenant_b", "key_3")
    end

    test "is a no-op when tenant has no cached entries" do
      Cache.put("tenant_b", "key_1", "value_1")
      Process.sleep(10)

      # Flushing a tenant that has no entries should succeed without affecting others
      assert :ok = Cache.flush_tenant("tenant_nonexistent")

      # Existing entries should be unaffected
      assert {:ok, "value_1"} = Cache.get("tenant_b", "key_1")
    end

    test "is synchronous — entries are removed before call returns" do
      Cache.put("tenant_a", "key_1", "dek_1")
      Process.sleep(10)

      assert {:ok, "dek_1"} = Cache.get("tenant_a", "key_1")

      # flush_tenant is a GenServer.call (synchronous)
      :ok = Cache.flush_tenant("tenant_a")

      # Immediately after the call returns, entries should be gone
      assert :miss = Cache.get("tenant_a", "key_1")
    end
  end
end
