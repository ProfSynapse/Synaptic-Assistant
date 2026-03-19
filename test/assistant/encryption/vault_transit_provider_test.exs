defmodule Assistant.Encryption.VaultTransitProviderTest do
  use ExUnit.Case, async: false

  alias Assistant.Encryption.VaultTransitProvider

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

    on_exit(fn ->
      Application.put_env(:assistant, :content_crypto, original_config)
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
end
