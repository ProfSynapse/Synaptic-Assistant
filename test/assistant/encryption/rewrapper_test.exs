defmodule Assistant.Encryption.RewrapperTest do
  use Assistant.DataCase
  alias Assistant.Encryption.Rewrapper
  alias Assistant.Schemas.ExecutionLog

  setup do
    bypass = Bypass.open()
    original_config = Application.get_env(:assistant, :content_crypto)
    
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

  describe "rewrap_schema/3" do
    test "dry_run: true does not change record", %{bypass: bypass} do
      {_user, _identity, conversation} = Assistant.ChannelFixtures.user_with_conversation_fixture()

      # Insert an ExecutionLog with simple parameters_encrypted
      {:ok, log} = 
        %ExecutionLog{}
        |> ExecutionLog.changeset(%{
          skill_id: "test",
          conversation_id: conversation.id,
          parameters_encrypted: %{
            "wrapped_dek" => "vault:v1:some_crypt_text",
            "key_version" => 1,
            "ciphertext" => "..."
          }
        })
        |> Repo.insert()

      # Setup bypass just in case it hits, but it shouldn't for dry run
      Bypass.down(bypass)

      result = Rewrapper.rewrap_schema(ExecutionLog, :parameters_encrypted, dry_run: true)

      assert result == %{success: 1, failed: 0, skipped: 0}
      
      # Should not have changed
      reloaded = Repo.get(ExecutionLog, log.id)
      assert reloaded.parameters_encrypted["wrapped_dek"] == "vault:v1:some_crypt_text"
    end

    test "dry_run: false updates wrapped_dek when new key version is returned", %{bypass: bypass} do
      {_user, _identity, conversation} = Assistant.ChannelFixtures.user_with_conversation_fixture()

      Bypass.expect_once(bypass, "POST", "/v1/transit/rewrap/test-key", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{
          "data" => %{
            "ciphertext" => "vault:v2:new_crypt_text"
          }
        }))
      end)

      {:ok, log} = 
        %ExecutionLog{}
        |> ExecutionLog.changeset(%{
          skill_id: "test",
          conversation_id: conversation.id,
          parameters_encrypted: %{
            "wrapped_dek" => "vault:v1:old_crypt_text",
            "key_version" => 1,
            "ciphertext" => "..."
          }
        })
        |> Repo.insert()

      result = Rewrapper.rewrap_schema(ExecutionLog, :parameters_encrypted, dry_run: false)

      assert result == %{success: 1, failed: 0, skipped: 0}

      reloaded = Repo.get(ExecutionLog, log.id)
      assert reloaded.parameters_encrypted["wrapped_dek"] == "vault:v2:new_crypt_text"
      assert reloaded.parameters_encrypted["key_version"] == 2
    end
    
    test "skips rewrap if return value is identical", %{bypass: bypass} do
      {_user, _identity, conversation} = Assistant.ChannelFixtures.user_with_conversation_fixture()

      # Transit can return same wrapped_dek if already wrapped with latest key version
      Bypass.expect_once(bypass, "POST", "/v1/transit/rewrap/test-key", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{
          "data" => %{
            "ciphertext" => "vault:v2:already_latest_crypt_text"
          }
        }))
      end)

      {:ok, _log} = 
        %ExecutionLog{}
        |> ExecutionLog.changeset(%{
          skill_id: "test",
          conversation_id: conversation.id,
          parameters_encrypted: %{
            "wrapped_dek" => "vault:v2:already_latest_crypt_text",
            "key_version" => 2,
            "ciphertext" => "..."
          }
        })
        |> Repo.insert()

      result = Rewrapper.rewrap_schema(ExecutionLog, :parameters_encrypted, dry_run: false)

      assert result == %{success: 0, failed: 0, skipped: 1}
    end
    
    test "skips records without properly shaped params", %{bypass: _bypass} do
      {_user, _identity, conversation} = Assistant.ChannelFixtures.user_with_conversation_fixture()

      {:ok, _log} = 
        %ExecutionLog{}
        |> ExecutionLog.changeset(%{
          skill_id: "test",
          conversation_id: conversation.id,
          parameters_encrypted: %{"missing" => "keys"}
        })
        |> Repo.insert()

      result = Rewrapper.rewrap_schema(ExecutionLog, :parameters_encrypted, dry_run: false)
      assert result == %{success: 0, failed: 0, skipped: 1}
    end
  end
end
