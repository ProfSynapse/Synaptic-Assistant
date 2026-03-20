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

  describe "rewrap_schema/3 per-tenant scoping" do
    setup %{bypass: _bypass} do
      {_user, _identity, conversation} = Assistant.ChannelFixtures.user_with_conversation_fixture()

      ba_a =
        %Assistant.Schemas.BillingAccount{}
        |> Assistant.Schemas.BillingAccount.changeset(%{name: "Tenant A", plan: "free"})
        |> Repo.insert!()

      ba_b =
        %Assistant.Schemas.BillingAccount{}
        |> Assistant.Schemas.BillingAccount.changeset(%{name: "Tenant B", plan: "free"})
        |> Repo.insert!()

      {:ok, conversation: conversation, tenant_a_id: ba_a.id, tenant_b_id: ba_b.id}
    end

    test "billing_account_id opt restricts rewrap to matching tenant only", %{
      bypass: bypass,
      conversation: conversation,
      tenant_a_id: tenant_a_id,
      tenant_b_id: tenant_b_id
    } do
      # Insert a log for tenant_a
      {:ok, log_a} =
        %ExecutionLog{}
        |> ExecutionLog.changeset(%{
          skill_id: "test-a",
          conversation_id: conversation.id,
          billing_account_id: tenant_a_id,
          parameters_encrypted: %{
            "wrapped_dek" => "vault:v1:tenant_a_dek",
            "key_version" => 1,
            "ciphertext" => "..."
          }
        })
        |> Repo.insert()

      # Insert a log for tenant_b
      {:ok, log_b} =
        %ExecutionLog{}
        |> ExecutionLog.changeset(%{
          skill_id: "test-b",
          conversation_id: conversation.id,
          billing_account_id: tenant_b_id,
          parameters_encrypted: %{
            "wrapped_dek" => "vault:v1:tenant_b_dek",
            "key_version" => 1,
            "ciphertext" => "..."
          }
        })
        |> Repo.insert()

      # Bypass returns a new wrapped_dek for any rewrap request
      Bypass.expect(bypass, "POST", "/v1/transit/rewrap/test-key", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{
          "data" => %{"ciphertext" => "vault:v3:rewrapped_dek"}
        }))
      end)

      # Rewrap only tenant_a rows
      result = Rewrapper.rewrap_schema(ExecutionLog, :parameters_encrypted,
        dry_run: false,
        billing_account_id: tenant_a_id
      )

      assert result.success == 1
      assert result.failed == 0

      # Verify tenant_a log was updated
      reloaded_a = Repo.get(ExecutionLog, log_a.id)
      assert reloaded_a.parameters_encrypted["wrapped_dek"] == "vault:v3:rewrapped_dek"
      assert reloaded_a.parameters_encrypted["key_version"] == 3

      # Verify tenant_b log was NOT touched (still has original wrapped_dek)
      reloaded_b = Repo.get(ExecutionLog, log_b.id)
      assert reloaded_b.parameters_encrypted["wrapped_dek"] == "vault:v1:tenant_b_dek"
      assert reloaded_b.parameters_encrypted["key_version"] == 1
    end

    test "without billing_account_id opt, processes all tenants", %{
      bypass: bypass,
      conversation: conversation,
      tenant_a_id: tenant_a_id,
      tenant_b_id: tenant_b_id
    } do
      for {tenant_id, label} <- [{tenant_a_id, "a"}, {tenant_b_id, "b"}] do
        %ExecutionLog{}
        |> ExecutionLog.changeset(%{
          skill_id: "test-#{label}",
          conversation_id: conversation.id,
          billing_account_id: tenant_id,
          parameters_encrypted: %{
            "wrapped_dek" => "vault:v1:#{label}_dek",
            "key_version" => 1,
            "ciphertext" => "..."
          }
        })
        |> Repo.insert!()
      end

      Bypass.expect(bypass, "POST", "/v1/transit/rewrap/test-key", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{
          "data" => %{"ciphertext" => "vault:v3:new_dek"}
        }))
      end)

      result = Rewrapper.rewrap_schema(ExecutionLog, :parameters_encrypted, dry_run: false)

      # Both tenants should be processed
      assert result.success == 2
      assert result.failed == 0
    end
  end
end
