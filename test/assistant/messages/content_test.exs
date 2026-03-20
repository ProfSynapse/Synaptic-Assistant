defmodule Assistant.Messages.ContentTest do
  use Assistant.DataCase, async: false

  alias Assistant.Encryption
  alias Assistant.Messages.Content, as: MessageContent
  alias Assistant.Memory.Store
  alias Assistant.Schemas.{BillingAccount, Conversation, Message, User}

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

  defp create_user(billing_account) do
    %User{}
    |> User.changeset(%{
      external_id: "msg-test-#{System.unique_integer([:positive])}",
      channel: "test",
      billing_account_id: billing_account.id
    })
    |> Repo.insert!()
  end

  defp create_conversation(user) do
    %Conversation{}
    |> Conversation.changeset(%{channel: "test", user_id: user.id})
    |> Repo.insert!()
  end

  describe "encrypt/decrypt round-trip via Store.append_message" do
    test "raw DB row has content nil (virtual) and content_encrypted populated" do
      ba = create_billing_account("MsgTest")
      user = create_user(ba)
      conversation = create_conversation(user)

      {:ok, hydrated_msg} =
        Store.append_message(conversation.id, %{role: "user", content: "secret message"})

      # The returned message is already hydrated — content should be restored
      assert hydrated_msg.content == "secret message"

      # Query the raw DB row — content is virtual so it won't be loaded
      raw_msg = Repo.get!(Message, hydrated_msg.id)
      assert raw_msg.content == nil
      assert is_map(raw_msg.content_encrypted)
      assert Map.has_key?(raw_msg.content_encrypted, "ciphertext")
    end

    test "hydrate_for_conversation! restores original plaintext from encrypted row" do
      ba = create_billing_account("MsgHydrate")
      user = create_user(ba)
      conversation = create_conversation(user)

      plaintext = "the quick brown fox jumps over the lazy dog"

      {:ok, _msg} =
        Store.append_message(conversation.id, %{role: "assistant", content: plaintext})

      # Fetch raw messages (not hydrated) and hydrate manually
      raw_messages =
        from(m in Message, where: m.conversation_id == ^conversation.id)
        |> Repo.all()

      assert length(raw_messages) == 1
      [raw] = raw_messages
      assert raw.content == nil

      # Hydrate via the content module
      hydrated = MessageContent.hydrate_for_conversation!(conversation.id, raw_messages)
      assert length(hydrated) == 1
      assert hd(hydrated).content == plaintext
    end

    test "messages from different billing accounts use different AAD contexts" do
      ba_a = create_billing_account("TenantA-Msg")
      ba_b = create_billing_account("TenantB-Msg")
      user_a = create_user(ba_a)
      user_b = create_user(ba_b)
      conv_a = create_conversation(user_a)
      conv_b = create_conversation(user_b)

      plaintext = "cross-tenant test content"

      {:ok, msg_a} =
        Store.append_message(conv_a.id, %{role: "user", content: plaintext})

      {:ok, msg_b} =
        Store.append_message(conv_b.id, %{role: "user", content: plaintext})

      # Both should decrypt fine in their own context
      assert msg_a.content == plaintext
      assert msg_b.content == plaintext

      # Get raw encrypted payloads
      raw_a = Repo.get!(Message, msg_a.id)
      raw_b = Repo.get!(Message, msg_b.id)

      # The encrypted payloads should differ (different keys/AAD)
      assert raw_a.content_encrypted["ciphertext"] != raw_b.content_encrypted["ciphertext"]

      # Attempting to decrypt msg_a's payload under msg_b's context should fail
      # Build field_ref for msg_a but with tenant B's billing_account_id
      field_ref_wrong = %{
        billing_account_id: ba_b.id,
        table: :messages,
        field: :content,
        row_id: msg_a.id
      }

      assert {:error, :decrypt_failed} =
               Encryption.decrypt(field_ref_wrong, raw_a.content_encrypted)
    end
  end
end
