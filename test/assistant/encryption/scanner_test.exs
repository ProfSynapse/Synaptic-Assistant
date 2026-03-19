defmodule Assistant.Encryption.ScannerTest do
  use Assistant.DataCase
  alias Assistant.Encryption.Scanner
  alias Assistant.Schemas.ExecutionLog

  setup do
    original_config = Application.get_env(:assistant, :content_crypto)
    
    Application.put_env(:assistant, :content_crypto, [
      mode: :local_cloak,
      local: [
        key: :crypto.strong_rand_bytes(32)
      ]
    ])

    on_exit(fn ->
      Application.put_env(:assistant, :content_crypto, original_config)
    end)

    {_user, _identity, conversation} = Assistant.ChannelFixtures.user_with_conversation_fixture()
    {:ok, conversation: conversation}
  end

  describe "scan/3 integrity check" do
    setup do
      {:ok, billing_account} = 
        %Assistant.Schemas.BillingAccount{}
        |> Assistant.Schemas.BillingAccount.changeset(%{
          name: "Test Account",
          plan: "free"
        })
        |> Repo.insert()
      
      {:ok, billing_account: billing_account}
    end

    test "correctly identifies valid records", %{conversation: conversation, billing_account: billing_account} do
      billing_id = billing_account.id
      parameters = %{"hello" => "world"}
      
      field_ref = %{
        billing_account_id: billing_id,
        table: "execution_logs",
        field: "parameters_encrypted"
        # row_id will be added by the scanner implicitly during the check, but verify encrypt sets it correctly?
        # Actually encrypt() uses field_ref for AAD. The schema insertion isn't perfect yet since identity ID isn't known 
        # until inserted, so we must insert then update, or we mock the encrypt.
      }
      
      # Since we can't easily encrypt BEFORE we know the row ID if aad_version requires row_id
      # Fortunately, Assistant.Encryption.Context uses table and field mostly, and ignores row_id if not strictly required, 
      # but let's insert first, then encrypt with knowledge of row.id.
      {:ok, log} = 
        %ExecutionLog{}
        |> ExecutionLog.changeset(%{
          skill_id: "test",
          conversation_id: conversation.id,
          parameters: parameters,
          billing_account_id: billing_id
        })
        |> Repo.insert()

      # Now encrypt properly
      field_ref = Map.put(field_ref, :row_id, log.id)
      {:ok, encrypted} = Assistant.Encryption.encrypt(field_ref, Jason.encode!(parameters))

      {:ok, _} = 
        log
        |> Ecto.Changeset.change(%{parameters_encrypted: encrypted})
        |> Repo.update()
        
      result = Scanner.scan(ExecutionLog, :parameters_encrypted, plaintext_field: :parameters)
      
      assert result.valid == 1
      assert result.corrupted == 0
      assert result.skipped == 0
    end

    test "identifies corrupted records with invalid ciphertext", %{conversation: conversation, billing_account: billing_account} do
      {:ok, log} = 
        %ExecutionLog{}
        |> ExecutionLog.changeset(%{
          skill_id: "test",
          conversation_id: conversation.id,
          billing_account_id: billing_account.id,
          parameters_encrypted: %{
            "ciphertext" => "invalid_base64!",
            "nonce" => "...",
            "tag" => "...",
            "key_version" => 1,
            "algorithm" => "aes",
            "aad_version" => 1
          }
        })
        |> Repo.insert()

      result = Scanner.scan(ExecutionLog, :parameters_encrypted)
      
      assert result.valid == 0
      assert result.corrupted == 1
      log_id = log.id
      assert [{^log_id, _reason}] = result.failures
    end

    test "repairs records if plaintext matches but ciphertext is corrupt and repair: true", %{conversation: conversation, billing_account: billing_account} do
      billing_id = billing_account.id
      parameters = %{"fix" => "me"}

      {:ok, log} = 
        %ExecutionLog{}
        |> ExecutionLog.changeset(%{
          skill_id: "test",
          conversation_id: conversation.id,
          parameters: parameters,
          billing_account_id: billing_id,
          parameters_encrypted: %{
            "ciphertext" => Base.encode64("corrupt"), # Valid base64 but fails GCM auth tag
            "nonce" => Base.encode64(:crypto.strong_rand_bytes(12)),
            "tag" => Base.encode64(:crypto.strong_rand_bytes(16)),
            "key_version" => 1,
            "algorithm" => "aes_256_gcm",
            "aad_version" => 1
          }
        })
        |> Repo.insert()

      result = Scanner.scan(ExecutionLog, :parameters_encrypted, plaintext_field: :parameters, repair: true)
      
      assert result.valid == 0
      assert result.corrupted == 0
      assert result.repaired == 1
      
      # Verify it's actually fixed
      reloaded = Repo.get(ExecutionLog, log.id)
      
      field_ref = %{
        billing_account_id: billing_id,
        table: "execution_logs",
        field: "parameters_encrypted",
        row_id: log.id
      }

      assert {:ok, json} = Assistant.Encryption.decrypt(field_ref, reloaded.parameters_encrypted)
      assert Jason.decode!(json) == parameters
    end
  end
end
