# test/assistant/memory/store_test.exs — Smoke tests for Memory.Store.
#
# Verifies the module compiles and basic changeset validation works.
# Comprehensive database integration tests belong in the TEST phase.

defmodule Assistant.Memory.StoreTest do
  use Assistant.DataCase, async: true

  alias Assistant.Memory.Store
  alias Assistant.Schemas.{Conversation, MemoryEntry, Message, User}

  describe "module compilation" do
    test "Store module is loaded and exports expected functions" do
      assert function_exported?(Store, :create_conversation, 1)
      assert function_exported?(Store, :get_conversation, 1)
      assert function_exported?(Store, :get_or_create_conversation, 2)
      assert function_exported?(Store, :append_message, 2)
      assert function_exported?(Store, :list_messages, 2)
      assert function_exported?(Store, :get_messages_in_range, 3)
      assert function_exported?(Store, :update_summary, 3)
      assert function_exported?(Store, :create_memory_entry, 1)
      assert function_exported?(Store, :get_memory_entry, 1)
      assert function_exported?(Store, :update_memory_entry_accessed_at, 1)
      assert function_exported?(Store, :list_memory_entries, 1)
    end
  end

  # Helper to insert a test user
  defp create_test_user do
    %User{}
    |> User.changeset(%{
      external_id: "test-user-#{System.unique_integer([:positive])}",
      channel: "test"
    })
    |> Repo.insert!()
  end

  describe "create_conversation/1" do
    test "creates a conversation with valid attrs" do
      user = create_test_user()

      assert {:ok, %Conversation{} = conv} =
               Store.create_conversation(%{channel: "test", user_id: user.id})

      assert conv.channel == "test"
      assert conv.user_id == user.id
      assert conv.status == "active"
    end

    test "returns error changeset when channel is missing" do
      user = create_test_user()
      assert {:error, %Ecto.Changeset{}} = Store.create_conversation(%{user_id: user.id})
    end
  end

  describe "get_conversation/1" do
    test "returns {:ok, conversation} when found" do
      user = create_test_user()
      {:ok, conv} = Store.create_conversation(%{channel: "test", user_id: user.id})

      assert {:ok, %Conversation{id: id}} = Store.get_conversation(conv.id)
      assert id == conv.id
    end

    test "returns {:error, :not_found} for missing id" do
      assert {:error, :not_found} = Store.get_conversation(Ecto.UUID.generate())
    end
  end

  describe "append_message/2" do
    test "inserts a message and touches conversation" do
      user = create_test_user()
      {:ok, conv} = Store.create_conversation(%{channel: "test", user_id: user.id})

      assert {:ok, %Message{} = msg} =
               Store.append_message(conv.id, %{role: "user", content: "hello"})

      assert msg.conversation_id == conv.id
      assert msg.role == "user"
      assert msg.content == "hello"
    end

    test "returns error for invalid role" do
      user = create_test_user()
      {:ok, conv} = Store.create_conversation(%{channel: "test", user_id: user.id})

      assert {:error, %Ecto.Changeset{}} =
               Store.append_message(conv.id, %{role: "invalid_role", content: "hello"})
    end
  end

  describe "list_messages/2" do
    test "returns messages in ascending order by default" do
      user = create_test_user()
      {:ok, conv} = Store.create_conversation(%{channel: "test", user_id: user.id})

      {:ok, _m1} = Store.append_message(conv.id, %{role: "user", content: "first"})
      {:ok, _m2} = Store.append_message(conv.id, %{role: "assistant", content: "second"})

      messages = Store.list_messages(conv.id)
      assert length(messages) == 2
      assert Enum.at(messages, 0).content == "first"
      assert Enum.at(messages, 1).content == "second"
    end

    test "respects limit and offset" do
      user = create_test_user()
      {:ok, conv} = Store.create_conversation(%{channel: "test", user_id: user.id})

      for i <- 1..5 do
        Store.append_message(conv.id, %{role: "user", content: "msg-#{i}"})
      end

      messages = Store.list_messages(conv.id, limit: 2, offset: 1)
      assert length(messages) == 2
    end
  end

  describe "create_memory_entry/1" do
    test "creates a memory entry with valid attrs" do
      assert {:ok, %MemoryEntry{} = entry} =
               Store.create_memory_entry(%{content: "Remember: user prefers dark mode"})

      assert entry.content == "Remember: user prefers dark mode"
      assert entry.tags == []
      assert entry.importance == Decimal.new("0.50")
    end

    test "validates importance range" do
      assert {:error, %Ecto.Changeset{} = cs} =
               Store.create_memory_entry(%{content: "test", importance: Decimal.new("2.0")})

      assert errors_on(cs)[:importance] != nil
    end
  end

  describe "get_memory_entry/1" do
    test "returns entry with preloaded entity_mentions" do
      {:ok, entry} = Store.create_memory_entry(%{content: "test memory"})

      assert {:ok, %MemoryEntry{} = fetched} = Store.get_memory_entry(entry.id)
      assert fetched.id == entry.id
      assert is_list(fetched.entity_mentions)
    end

    test "returns {:error, :not_found} for missing id" do
      assert {:error, :not_found} = Store.get_memory_entry(Ecto.UUID.generate())
    end
  end

  describe "list_memory_entries/1" do
    test "returns entries filtered by user_id" do
      user = create_test_user()

      {:ok, _e1} =
        Store.create_memory_entry(%{content: "scoped", user_id: user.id})

      {:ok, _e2} =
        Store.create_memory_entry(%{content: "unscoped"})

      entries = Store.list_memory_entries(user_id: user.id)
      assert length(entries) == 1
      assert hd(entries).content == "scoped"
    end
  end
end
