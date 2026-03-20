# test/assistant/encryption/repair_worker_test.exs — Tests for RepairWorker Oban job
# enqueue on decrypt failure and direct perform/1 behavior.
#
# Related files:
#   - lib/assistant/encryption/repair_worker.ex (Oban worker for targeted row repair)
#   - lib/assistant/memory/content.ex (enqueues RepairWorker on hydration failure)

defmodule Assistant.Encryption.RepairWorkerTest do
  use Assistant.DataCase

  alias Assistant.Encryption
  alias Assistant.Encryption.RepairWorker
  alias Assistant.Schemas.{BillingAccount, ExecutionLog, MemoryEntry, User}

  @moduletag :capture_log

  setup do
    original_config = Application.get_env(:assistant, :content_crypto)

    Application.put_env(:assistant, :content_crypto,
      mode: :local_cloak,
      local: [key: :crypto.strong_rand_bytes(32)]
    )

    on_exit(fn ->
      Application.put_env(:assistant, :content_crypto, original_config)
    end)

    :ok
  end

  defp create_billing_account(name) do
    %BillingAccount{}
    |> BillingAccount.changeset(%{name: name, plan: "free"})
    |> Repo.insert!()
  end

  defp create_user_with_billing(billing_account) do
    %User{}
    |> User.changeset(%{
      external_id: "#{System.unique_integer([:positive])}",
      channel: "telegram",
      billing_account_id: billing_account.id
    })
    |> Repo.insert!()
  end

  describe "Memory.Content.hydrate/1 enqueue on decrypt failure" do
    test "enqueues RepairWorker when decryption fails and returns entry with nil content" do
      ba = create_billing_account("Test Account")
      user = create_user_with_billing(ba)

      entry_id = Ecto.UUID.generate()

      # Insert a memory entry with intentionally corrupt encrypted payload
      {:ok, entry_id_bin} = Ecto.UUID.dump(entry_id)
      {:ok, user_id_bin} = Ecto.UUID.dump(user.id)
      now = DateTime.utc_now()

      corrupt_payload = %{
        "ciphertext" => Base.encode64("corrupt_data"),
        "nonce" => Base.encode64(:crypto.strong_rand_bytes(12)),
        "tag" => Base.encode64(:crypto.strong_rand_bytes(16)),
        "key_version" => 1,
        "algorithm" => "aes_256_gcm",
        "aad_version" => 1
      }

      Ecto.Adapters.SQL.query!(
        Repo,
        """
        INSERT INTO memory_entries
          (id, user_id, title, content_encrypted, source_type,
           importance, decay_factor, tags, search_queries, access_count,
           inserted_at, updated_at)
        VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12)
        """,
        [
          entry_id_bin,
          user_id_bin,
          "Test memory",
          corrupt_payload,
          "user_explicit",
          Decimal.new("0.50"),
          Decimal.new("1.00"),
          [],
          [],
          0,
          now,
          now
        ]
      )

      entry = Repo.get!(MemoryEntry, entry_id)

      # Hydrate should NOT raise — it returns {:ok, entry} with content set to nil.
      # In inline Oban mode, the RepairWorker job is inserted AND executed immediately.
      # We capture logs to verify both the enqueue and the worker execution happened.
      import ExUnit.CaptureLog

      logs =
        capture_log(fn ->
          {:ok, hydrated} = Assistant.Memory.Content.hydrate(entry)
          # Content should be nil because decryption failed
          assert hydrated.content == nil
        end)

      # Verify the enqueue log message proves RepairWorker was enqueued
      assert logs =~ "enqueueing repair"
      # Verify the RepairWorker actually executed (inline mode)
      assert logs =~ "RepairWorker"
      assert logs =~ entry_id
    end
  end

  describe "RepairWorker.perform/1 direct invocation" do
    test "handles missing row gracefully (returns :ok)" do
      job = %Oban.Job{
        args: %{
          "schema" => "Assistant.Schemas.MemoryEntry",
          "id" => Ecto.UUID.generate()
        }
      }

      assert :ok = RepairWorker.perform(job)
    end

    test "handles unknown schema gracefully (returns :ok)" do
      job = %Oban.Job{
        args: %{
          "schema" => "Assistant.Schemas.NonExistent",
          "id" => Ecto.UUID.generate()
        }
      }

      assert :ok = RepairWorker.perform(job)
    end

    test "attempts repair on ExecutionLog with corrupted encrypted field" do
      ba = create_billing_account("Repair Test")
      {_user, _identity, conversation} = Assistant.ChannelFixtures.user_with_conversation_fixture()

      {:ok, log} =
        %ExecutionLog{}
        |> ExecutionLog.changeset(%{
          skill_id: "test",
          conversation_id: conversation.id,
          billing_account_id: ba.id,
          parameters_encrypted: %{
            "ciphertext" => Base.encode64("corrupt"),
            "nonce" => Base.encode64(:crypto.strong_rand_bytes(12)),
            "tag" => Base.encode64(:crypto.strong_rand_bytes(16)),
            "wrapped_dek" => "not_a_real_dek",
            "key_version" => 1,
            "algorithm" => "aes_256_gcm",
            "aad_version" => 1
          }
        })
        |> Repo.insert()

      job = %Oban.Job{
        args: %{
          "schema" => "Assistant.Schemas.ExecutionLog",
          "id" => log.id
        }
      }

      # Should not raise — logs warning and returns :ok
      assert :ok = RepairWorker.perform(job)
    end

    test "detects already-decryptable field and logs success" do
      ba = create_billing_account("Decrypt OK Test")
      {_user, _identity, conversation} = Assistant.ChannelFixtures.user_with_conversation_fixture()

      field_ref = %{
        billing_account_id: ba.id,
        table: "execution_logs",
        field: "parameters_encrypted",
        row_id: nil
      }

      # Create a properly encrypted payload
      {:ok, encrypted} = Encryption.encrypt(field_ref, "test params")

      {:ok, log} =
        %ExecutionLog{}
        |> ExecutionLog.changeset(%{
          skill_id: "test",
          conversation_id: conversation.id,
          billing_account_id: ba.id,
          parameters_encrypted: encrypted
        })
        |> Repo.insert()

      job = %Oban.Job{
        args: %{
          "schema" => "Assistant.Schemas.ExecutionLog",
          "id" => log.id
        }
      }

      # Should detect that the payload decrypts fine and return :ok
      assert :ok = RepairWorker.perform(job)
    end
  end
end
