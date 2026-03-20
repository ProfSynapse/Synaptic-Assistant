defmodule Assistant.Encryption.VaultTransitProviderTest do
  use ExUnit.Case, async: false

  alias Assistant.Encryption.VaultTransitProvider

  @fuse_name :vault_transit

  setup do
    bypass = Bypass.open()

    original_config = Application.get_env(:assistant, :content_crypto)

    # Configure vault to hit our bypass instance
    Application.put_env(:assistant, :content_crypto, [
      provider: Assistant.Encryption.VaultTransitProvider,
      vault: [
        addr: "http://127.0.0.1:#{bypass.port}",
        token: "test-token",
        transit_mount: "transit",
        transit_key: "test-key"
      ]
    ])

    # Ensure the fuse is installed and reset for each test
    VaultTransitProvider.install_fuse()
    :fuse.reset(@fuse_name)

    on_exit(fn ->
      Application.put_env(:assistant, :content_crypto, original_config)
      # Reset fuse between tests so blown state doesn't leak
      :fuse.reset(@fuse_name)
    end)

    {:ok, bypass: bypass}
  end

  describe "rewrap/2" do
    test "successfully rewraps ciphertext and parses new version", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/v1/transit/rewrap/test-key", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        params = Jason.decode!(body)

        assert params["ciphertext"] == "vault:v1:oldciphertext"
        assert params["context"] # derivation context should be here

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{
          "data" => %{
            "ciphertext" => "vault:v2:newciphertext"
          }
        }))
      end)

      field_ref = %{
        billing_account_id: Ecto.UUID.generate(),
        table: "messages",
        field: "content_encrypted",
        row_id: 123
      }

      assert {:ok, %{wrapped_dek: "vault:v2:newciphertext", key_version: 2}} =
               VaultTransitProvider.rewrap(field_ref, "vault:v1:oldciphertext")
    end

    test "handles vault error appropriately", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/v1/transit/rewrap/test-key", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(400, Jason.encode!(%{
          "errors" => ["invalid ciphertext"]
        }))
      end)

      field_ref = %{
        billing_account_id: Ecto.UUID.generate(),
        table: "messages",
        field: "content_encrypted",
        row_id: 123
      }

      assert {:error, {:vault_error, 400, %{"errors" => ["invalid ciphertext"]}}} =
               VaultTransitProvider.rewrap(field_ref, "vault:v1:oldciphertext")
    end
  end

  describe "circuit breaker" do
    test "opens after 5 failures and returns :vault_circuit_open without HTTP call", %{bypass: bypass} do
      field_ref = %{
        billing_account_id: Ecto.UUID.generate(),
        table: "messages",
        field: "content_encrypted",
        row_id: 123
      }

      # Return 500 errors to trigger fuse melts
      Bypass.expect(bypass, "POST", "/v1/transit/rewrap/test-key", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(500, Jason.encode!(%{"errors" => ["internal error"]}))
      end)

      # Trigger 6 failures to blow the fuse (threshold is 5 melts, fuse blows on exceeding)
      for _i <- 1..6 do
        assert {:error, {:vault_error, 500, _}} =
                 VaultTransitProvider.rewrap(field_ref, "vault:v1:oldciphertext")
      end

      # Now the fuse should be blown — no HTTP call made
      # Bypass.down ensures no requests go through; if one does, the test fails
      Bypass.down(bypass)

      assert {:error, :vault_circuit_open} =
               VaultTransitProvider.rewrap(field_ref, "vault:v1:oldciphertext")
    end

    test "install_fuse/0 is idempotent" do
      assert :ok = VaultTransitProvider.install_fuse()
      assert :ok = VaultTransitProvider.install_fuse()
    end

    test "successful requests do not melt the fuse", %{bypass: bypass} do
      field_ref = %{
        billing_account_id: Ecto.UUID.generate(),
        table: "messages",
        field: "content_encrypted",
        row_id: 123
      }

      # Set up successful responses
      Bypass.expect(bypass, "POST", "/v1/transit/rewrap/test-key", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{
          "data" => %{"ciphertext" => "vault:v2:newciphertext"}
        }))
      end)

      # Make several successful calls — fuse should stay closed
      for _i <- 1..10 do
        assert {:ok, _} = VaultTransitProvider.rewrap(field_ref, "vault:v1:oldciphertext")
      end

      # Fuse should still be ok
      assert :ok = :fuse.ask(@fuse_name, :sync)
    end
  end

  describe "encrypt/3 Vault unavailability" do
    test "encrypt returns error when Vault returns 503", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/v1/transit/datakey/plaintext/test-key", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(503, Jason.encode!(%{"errors" => ["service unavailable"]}))
      end)

      field_ref = %{
        billing_account_id: Ecto.UUID.generate(),
        table: "memory_entries",
        field: "content",
        row_id: Ecto.UUID.generate()
      }

      assert {:error, {:vault_error, 503, _}} =
               VaultTransitProvider.encrypt(field_ref, "hello world", [])
    end

    test "fuse is blown after 5 encrypt failures (503s)", %{bypass: bypass} do
      # Fuse should start healthy
      assert :ok = :fuse.ask(@fuse_name, :sync)

      Bypass.expect(bypass, "POST", "/v1/transit/datakey/plaintext/test-key", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(503, Jason.encode!(%{"errors" => ["service unavailable"]}))
      end)

      field_ref = %{
        billing_account_id: Ecto.UUID.generate(),
        table: "memory_entries",
        field: "content",
        row_id: Ecto.UUID.generate()
      }

      # Trigger 6 failures to blow the fuse (threshold is 5 melts in 10s)
      for _i <- 1..6 do
        assert {:error, {:vault_error, 503, _}} =
                 VaultTransitProvider.encrypt(field_ref, "hello world", [])
      end

      # Fuse should now be blown
      assert :blown = :fuse.ask(@fuse_name, :sync)

      # Subsequent calls should fail fast without HTTP call
      Bypass.down(bypass)

      assert {:error, :vault_circuit_open} =
               VaultTransitProvider.encrypt(field_ref, "hello world", [])
    end
  end

  describe "retry integration" do
    test "with_retry/1 does not retry on :vault_circuit_open" do
      # Blow the fuse directly (threshold is 5, need >5 to trip)
      for _i <- 1..6, do: :fuse.melt(@fuse_name)

      call_count = :counters.new(1, [:atomics])

      result =
        Assistant.Encryption.Retry.with_retry(fn ->
          :counters.add(call_count, 1, 1)

          # Simulate what the provider returns when fuse is blown
          {:error, :vault_circuit_open}
        end)

      assert {:error, :vault_circuit_open} = result
      # Should only be called once — no retries
      assert :counters.get(call_count, 1) == 1
    end

    test "with_retry/1 retries up to 2 times on transient errors then returns the error" do
      call_count = :counters.new(1, [:atomics])

      result =
        Assistant.Encryption.Retry.with_retry(fn ->
          :counters.add(call_count, 1, 1)
          {:error, :transient}
        end)

      assert {:error, :transient} = result
      # Initial call + 2 retries = 3 total calls
      assert :counters.get(call_count, 1) == 3
    end

    test "with_retry/1 returns immediately on success without retrying" do
      call_count = :counters.new(1, [:atomics])

      result =
        Assistant.Encryption.Retry.with_retry(fn ->
          :counters.add(call_count, 1, 1)
          {:ok, "decrypted"}
        end)

      assert {:ok, "decrypted"} = result
      assert :counters.get(call_count, 1) == 1
    end

    test "with_retry/1 succeeds on second attempt after transient failure" do
      call_count = :counters.new(1, [:atomics])

      result =
        Assistant.Encryption.Retry.with_retry(fn ->
          count = :counters.get(call_count, 1) + 1
          :counters.put(call_count, 1, count)

          if count <= 1 do
            {:error, :transient}
          else
            {:ok, "recovered"}
          end
        end)

      assert {:ok, "recovered"} = result
      # Initial call + 1 retry = 2 total calls
      assert :counters.get(call_count, 1) == 2
    end
  end
end
