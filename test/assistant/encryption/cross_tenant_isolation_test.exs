# test/assistant/encryption/cross_tenant_isolation_test.exs — Cross-tenant isolation
# tests for the encryption AAD binding.
#
# Verifies that ciphertext encrypted under one tenant's billing_account_id
# cannot be decrypted under a different tenant's context. Also verifies
# cross-table isolation (same tenant, different table name in AAD).
#
# Related files:
#   - lib/assistant/encryption/context.ex (AAD + derivation_context construction)
#   - lib/assistant/encryption/local_provider.ex (AES-256-GCM with AAD)
#   - lib/assistant/memory/content.ex (Content module hydrate path)

defmodule Assistant.Encryption.CrossTenantIsolationTest do
  use Assistant.DataCase

  alias Assistant.Encryption
  alias Assistant.Encryption.Context
  alias Assistant.Schemas.{BillingAccount, MemoryEntry, User}

  # Modifies Application config, cannot run async
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

  describe "cross-tenant AAD isolation (local provider)" do
    test "ciphertext encrypted under tenant A cannot be decrypted under tenant B" do
      row_id = Ecto.UUID.generate()

      field_ref_a = %{
        billing_account_id: "tenant_a",
        table: :memory_entries,
        field: :content,
        row_id: row_id
      }

      field_ref_b = %{
        billing_account_id: "tenant_b",
        table: :memory_entries,
        field: :content,
        row_id: row_id
      }

      plaintext = "This is tenant A's secret data"

      # Encrypt under tenant A's context
      {:ok, encrypted} = Encryption.encrypt(field_ref_a, plaintext)

      # Decrypt under tenant A succeeds
      assert {:ok, ^plaintext} = Encryption.decrypt(field_ref_a, encrypted)

      # Decrypt under tenant B fails — AAD mismatch AND derived key mismatch
      assert {:error, :decrypt_failed} = Encryption.decrypt(field_ref_b, encrypted)
    end

    test "AAD includes billing_account_id in the JSON payload" do
      ref_a = %{billing_account_id: "tenant_a", table: :t, field: :f, row_id: nil}
      ref_b = %{billing_account_id: "tenant_b", table: :t, field: :f, row_id: nil}

      aad_a = Context.aad(ref_a)
      aad_b = Context.aad(ref_b)

      # AADs must differ when billing_account_id differs
      assert aad_a != aad_b

      # Both must contain their respective billing_account_id
      assert aad_a =~ "tenant_a"
      assert aad_b =~ "tenant_b"
    end

    test "derivation context differs by billing_account_id" do
      ref_a = %{billing_account_id: "tenant_a", table: :t, field: :f, row_id: nil}
      ref_b = %{billing_account_id: "tenant_b", table: :t, field: :f, row_id: nil}

      dc_a = Context.derivation_context(ref_a)
      dc_b = Context.derivation_context(ref_b)

      # Derivation contexts must differ — produces different HMAC-derived keys
      assert dc_a != dc_b
    end
  end

  describe "cross-table isolation (same tenant, different table)" do
    test "ciphertext encrypted for one table cannot be decrypted for a different table" do
      row_id = Ecto.UUID.generate()
      billing_account_id = "tenant_shared"

      field_ref_messages = %{
        billing_account_id: billing_account_id,
        table: :messages,
        field: :content,
        row_id: row_id
      }

      field_ref_memory = %{
        billing_account_id: billing_account_id,
        table: :memory_entries,
        field: :content,
        row_id: row_id
      }

      plaintext = "Data bound to messages table"

      {:ok, encrypted} = Encryption.encrypt(field_ref_messages, plaintext)

      # Same table context succeeds
      assert {:ok, ^plaintext} = Encryption.decrypt(field_ref_messages, encrypted)

      # Different table context fails
      assert {:error, :decrypt_failed} = Encryption.decrypt(field_ref_memory, encrypted)
    end
  end

  describe "Content module tenant isolation (Memory.Content)" do
    test "memory entry encrypted under user A cannot be hydrated under user B's billing context" do
      # Create two billing accounts (two tenants)
      ba_a = create_billing_account("Tenant A")
      ba_b = create_billing_account("Tenant B")

      # Create users under each tenant
      user_a = create_user_with_billing(ba_a)
      user_b = create_user_with_billing(ba_b)

      plaintext = "Tenant A's confidential memory"

      # Create entry through Store (handles encryption pipeline)
      {:ok, entry} =
        Assistant.Memory.Store.create_memory_entry(%{
          content: plaintext,
          title: "Test memory",
          user_id: user_a.id,
          source_type: "user_explicit"
        })

      # Reload from DB to get raw struct (content virtual field will be nil)
      entry = Repo.get!(MemoryEntry, entry.id)

      # Hydrate under user A succeeds
      {:ok, hydrated_a} = Assistant.Memory.Content.hydrate(entry)
      assert hydrated_a.content == plaintext

      # Now simulate hydration under user B's context by swapping the user_id
      entry_as_b = %{entry | user_id: user_b.id}

      # Hydrate under user B — decrypt fails, content set to nil (repair enqueued)
      {:ok, hydrated_b} = Assistant.Memory.Content.hydrate(entry_as_b)
      assert hydrated_b.content == nil
    end
  end
end
