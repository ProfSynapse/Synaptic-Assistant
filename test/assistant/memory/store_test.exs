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
      # New unified conversation functions
      assert function_exported?(Store, :get_or_create_perpetual_conversation, 1)
      assert function_exported?(Store, :batch_append_messages, 2)
      assert function_exported?(Store, :list_memory_entries_for_user, 4)
      assert function_exported?(Store, :list_conversations_for_user, 4)
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

  # ---------------------------------------------------------------
  # get_or_create_conversation/2
  # ---------------------------------------------------------------

  describe "get_or_create_conversation/2" do
    test "creates a new conversation when none exists for user" do
      user = create_test_user()

      assert {:ok, %Conversation{} = conv} =
               Store.get_or_create_conversation(user.id, %{channel: "test"})

      assert conv.user_id == user.id
      assert conv.channel == "test"
      assert conv.status == "active"
    end

    test "returns existing active conversation for user" do
      user = create_test_user()
      {:ok, original} = Store.create_conversation(%{channel: "test", user_id: user.id})

      {:ok, found} = Store.get_or_create_conversation(user.id, %{channel: "test"})

      assert found.id == original.id
    end

    test "does not return closed conversations" do
      user = create_test_user()

      {:ok, closed} = Store.create_conversation(%{channel: "test", user_id: user.id})

      # Manually set to closed
      Repo.update!(Ecto.Changeset.change(closed, status: "closed"))

      {:ok, new_conv} = Store.get_or_create_conversation(user.id, %{channel: "test"})

      refute new_conv.id == closed.id
    end

    test "different users get different conversations" do
      user1 = create_test_user()
      user2 = create_test_user()

      {:ok, conv1} = Store.get_or_create_conversation(user1.id, %{channel: "test"})
      {:ok, conv2} = Store.get_or_create_conversation(user2.id, %{channel: "test"})

      refute conv1.id == conv2.id
    end
  end

  # ---------------------------------------------------------------
  # Multi-turn conversation history accumulation
  # ---------------------------------------------------------------

  describe "multi-turn conversation history" do
    test "messages accumulate correctly across multiple turns" do
      user = create_test_user()
      {:ok, conv} = Store.create_conversation(%{channel: "test", user_id: user.id})

      turns = [
        {"user", "Hello, how are you?"},
        {"assistant", "I'm doing well, thanks for asking!"},
        {"user", "Can you help me with a task?"},
        {"assistant", "Of course! What do you need?"},
        {"user", "I need to set up a meeting"}
      ]

      for {role, content} <- turns do
        {:ok, _msg} = Store.append_message(conv.id, %{role: role, content: content})
      end

      messages = Store.list_messages(conv.id)
      assert length(messages) == 5

      # Verify order preservation
      contents = Enum.map(messages, & &1.content)
      assert Enum.at(contents, 0) == "Hello, how are you?"
      assert Enum.at(contents, 4) == "I need to set up a meeting"

      # Verify roles alternate correctly
      roles = Enum.map(messages, & &1.role)
      assert roles == ["user", "assistant", "user", "assistant", "user"]
    end

    test "append_message updates last_active_at on conversation" do
      user = create_test_user()
      {:ok, conv} = Store.create_conversation(%{channel: "test", user_id: user.id})

      original_active_at = conv.last_active_at

      # Small delay to ensure timestamp difference
      Process.sleep(10)

      {:ok, _msg} = Store.append_message(conv.id, %{role: "user", content: "hello"})

      {:ok, updated_conv} = Store.get_conversation(conv.id)

      # last_active_at should be updated (or was nil before and now set)
      if original_active_at do
        assert DateTime.compare(updated_conv.last_active_at, original_active_at) == :gt
      else
        assert updated_conv.last_active_at != nil
      end
    end

    test "messages from different conversations are isolated" do
      user = create_test_user()
      {:ok, conv1} = Store.create_conversation(%{channel: "test", user_id: user.id})

      {:ok, conv2} =
        Store.create_conversation(%{
          channel: "test",
          user_id: user.id,
          agent_type: "sub_agent",
          parent_conversation_id: conv1.id
        })

      {:ok, _} = Store.append_message(conv1.id, %{role: "user", content: "conv1 msg"})
      {:ok, _} = Store.append_message(conv2.id, %{role: "user", content: "conv2 msg"})
      {:ok, _} = Store.append_message(conv1.id, %{role: "assistant", content: "conv1 reply"})

      conv1_msgs = Store.list_messages(conv1.id)
      conv2_msgs = Store.list_messages(conv2.id)

      assert length(conv1_msgs) == 2
      assert length(conv2_msgs) == 1
      assert Enum.all?(conv1_msgs, &(&1.conversation_id == conv1.id))
    end
  end

  # ---------------------------------------------------------------
  # list_messages/2 — ordering and pagination edge cases
  # ---------------------------------------------------------------

  describe "list_messages/2 — extended" do
    test "returns messages in descending order when requested" do
      user = create_test_user()
      {:ok, conv} = Store.create_conversation(%{channel: "test", user_id: user.id})

      {:ok, _} = Store.append_message(conv.id, %{role: "user", content: "first"})
      {:ok, _} = Store.append_message(conv.id, %{role: "assistant", content: "second"})

      messages = Store.list_messages(conv.id, order: :desc)
      assert length(messages) == 2
      assert Enum.at(messages, 0).content == "second"
      assert Enum.at(messages, 1).content == "first"
    end

    test "returns empty list for conversation with no messages" do
      user = create_test_user()
      {:ok, conv} = Store.create_conversation(%{channel: "test", user_id: user.id})

      assert Store.list_messages(conv.id) == []
    end

    test "returns empty list for non-existent conversation_id" do
      assert Store.list_messages(Ecto.UUID.generate()) == []
    end

    test "offset beyond available messages returns empty list" do
      user = create_test_user()
      {:ok, conv} = Store.create_conversation(%{channel: "test", user_id: user.id})

      {:ok, _} = Store.append_message(conv.id, %{role: "user", content: "only one"})

      assert Store.list_messages(conv.id, offset: 10) == []
    end
  end

  # ---------------------------------------------------------------
  # get_messages_in_range/3
  # ---------------------------------------------------------------

  describe "get_messages_in_range/3" do
    test "returns messages within the range (inclusive)" do
      user = create_test_user()
      {:ok, conv} = Store.create_conversation(%{channel: "test", user_id: user.id})

      {:ok, m1} = Store.append_message(conv.id, %{role: "user", content: "msg 1"})
      Process.sleep(5)
      {:ok, _m2} = Store.append_message(conv.id, %{role: "assistant", content: "msg 2"})
      Process.sleep(5)
      {:ok, m3} = Store.append_message(conv.id, %{role: "user", content: "msg 3"})
      Process.sleep(5)
      {:ok, _m4} = Store.append_message(conv.id, %{role: "assistant", content: "msg 4"})

      # Range from m1 to m3 should include m1, m2, m3
      messages = Store.get_messages_in_range(conv.id, m1.id, m3.id)

      assert length(messages) >= 3
      contents = Enum.map(messages, & &1.content)
      assert "msg 1" in contents
      assert "msg 2" in contents
      assert "msg 3" in contents
    end

    test "returns empty list when start message doesn't exist" do
      user = create_test_user()
      {:ok, conv} = Store.create_conversation(%{channel: "test", user_id: user.id})
      {:ok, m1} = Store.append_message(conv.id, %{role: "user", content: "msg 1"})

      assert Store.get_messages_in_range(conv.id, Ecto.UUID.generate(), m1.id) == []
    end

    test "returns empty list when end message doesn't exist" do
      user = create_test_user()
      {:ok, conv} = Store.create_conversation(%{channel: "test", user_id: user.id})
      {:ok, m1} = Store.append_message(conv.id, %{role: "user", content: "msg 1"})

      assert Store.get_messages_in_range(conv.id, m1.id, Ecto.UUID.generate()) == []
    end

    test "returns empty list for non-existent conversation" do
      assert Store.get_messages_in_range(
               Ecto.UUID.generate(),
               Ecto.UUID.generate(),
               Ecto.UUID.generate()
             ) == []
    end

    test "returns single message when start == end" do
      user = create_test_user()
      {:ok, conv} = Store.create_conversation(%{channel: "test", user_id: user.id})
      {:ok, m1} = Store.append_message(conv.id, %{role: "user", content: "only one"})

      messages = Store.get_messages_in_range(conv.id, m1.id, m1.id)
      assert length(messages) == 1
      assert hd(messages).content == "only one"
    end
  end

  # ---------------------------------------------------------------
  # update_summary/3,4 — compaction summary updates
  # ---------------------------------------------------------------

  describe "update_summary/3" do
    test "sets summary text and increments version" do
      user = create_test_user()
      {:ok, conv} = Store.create_conversation(%{channel: "test", user_id: user.id})

      assert conv.summary_version == 0
      assert conv.summary == nil

      {:ok, updated} = Store.update_summary(conv.id, "User discussed weather.", "test/model")

      assert updated.summary == "User discussed weather."
      assert updated.summary_version == 1
      assert updated.summary_model == "test/model"
    end

    test "incremental update further increments version" do
      user = create_test_user()
      {:ok, conv} = Store.create_conversation(%{channel: "test", user_id: user.id})

      {:ok, v1} = Store.update_summary(conv.id, "Summary v1", "model-a")
      assert v1.summary_version == 1

      {:ok, v2} = Store.update_summary(conv.id, "Summary v2 (includes v1)", "model-b")
      assert v2.summary_version == 2
      assert v2.summary == "Summary v2 (includes v1)"
      assert v2.summary_model == "model-b"
    end

    test "stores last_compacted_message_id when provided" do
      user = create_test_user()
      {:ok, conv} = Store.create_conversation(%{channel: "test", user_id: user.id})
      {:ok, msg} = Store.append_message(conv.id, %{role: "user", content: "boundary"})

      {:ok, updated} =
        Store.update_summary(conv.id, "Summary", "model",
          last_compacted_message_id: msg.id
        )

      assert updated.last_compacted_message_id == msg.id
    end

    test "returns {:error, :not_found} for non-existent conversation" do
      assert {:error, :not_found} =
               Store.update_summary(Ecto.UUID.generate(), "summary", "model")
    end
  end

  # ---------------------------------------------------------------
  # update_memory_entry_accessed_at/1
  # ---------------------------------------------------------------

  describe "update_memory_entry_accessed_at/1" do
    test "updates accessed_at timestamp" do
      {:ok, entry} = Store.create_memory_entry(%{content: "test memory"})

      original_accessed_at = entry.accessed_at

      Process.sleep(10)

      {:ok, updated} = Store.update_memory_entry_accessed_at(entry.id)

      assert updated.id == entry.id

      if original_accessed_at do
        assert DateTime.compare(updated.accessed_at, original_accessed_at) == :gt
      else
        assert updated.accessed_at != nil
      end
    end

    test "returns {:error, :not_found} for non-existent entry" do
      assert {:error, :not_found} =
               Store.update_memory_entry_accessed_at(Ecto.UUID.generate())
    end
  end

  # ---------------------------------------------------------------
  # list_memory_entries/1 — extended filter tests
  # ---------------------------------------------------------------

  describe "list_memory_entries/1 — filters" do
    test "filters by category" do
      user = create_test_user()

      {:ok, _} =
        Store.create_memory_entry(%{
          content: "preference entry",
          user_id: user.id,
          category: "preference"
        })

      {:ok, _} =
        Store.create_memory_entry(%{
          content: "fact entry",
          user_id: user.id,
          category: "fact"
        })

      entries = Store.list_memory_entries(user_id: user.id, category: "preference")
      assert length(entries) == 1
      assert hd(entries).content == "preference entry"
    end

    test "filters by minimum importance" do
      user = create_test_user()

      {:ok, _} =
        Store.create_memory_entry(%{
          content: "low importance",
          user_id: user.id,
          importance: Decimal.new("0.20")
        })

      {:ok, _} =
        Store.create_memory_entry(%{
          content: "high importance",
          user_id: user.id,
          importance: Decimal.new("0.90")
        })

      entries = Store.list_memory_entries(user_id: user.id, importance_min: 0.5)
      assert length(entries) == 1
      assert hd(entries).content == "high importance"
    end

    test "respects limit and offset" do
      user = create_test_user()

      for i <- 1..5 do
        Store.create_memory_entry(%{content: "entry #{i}", user_id: user.id})
      end

      entries = Store.list_memory_entries(user_id: user.id, limit: 2, offset: 1)
      assert length(entries) == 2
    end

    test "returns entries ordered by inserted_at descending" do
      user = create_test_user()

      {:ok, _} = Store.create_memory_entry(%{content: "older", user_id: user.id})
      Process.sleep(5)
      {:ok, _} = Store.create_memory_entry(%{content: "newer", user_id: user.id})

      entries = Store.list_memory_entries(user_id: user.id)
      assert length(entries) == 2
      # Most recent first
      assert Enum.at(entries, 0).content == "newer"
      assert Enum.at(entries, 1).content == "older"
    end
  end

  # ---------------------------------------------------------------
  # get_or_create_perpetual_conversation/1
  # ---------------------------------------------------------------

  describe "get_or_create_perpetual_conversation/1" do
    test "creates perpetual conversation for new user" do
      user = create_test_user()

      assert {:ok, %Conversation{} = conv} =
               Store.get_or_create_perpetual_conversation(user.id)

      assert conv.user_id == user.id
      assert conv.channel == "unified"
      assert conv.agent_type == "orchestrator"
      assert conv.status == "active"
    end

    test "returns same conversation on repeated calls" do
      user = create_test_user()

      {:ok, conv1} = Store.get_or_create_perpetual_conversation(user.id)
      {:ok, conv2} = Store.get_or_create_perpetual_conversation(user.id)

      assert conv1.id == conv2.id
    end

    test "different users get different perpetual conversations" do
      user1 = create_test_user()
      user2 = create_test_user()

      {:ok, conv1} = Store.get_or_create_perpetual_conversation(user1.id)
      {:ok, conv2} = Store.get_or_create_perpetual_conversation(user2.id)

      refute conv1.id == conv2.id
    end

    test "does not return a closed conversation" do
      user = create_test_user()
      {:ok, conv} = Store.get_or_create_perpetual_conversation(user.id)

      # Manually close it
      Repo.update!(Ecto.Changeset.change(conv, status: "closed"))

      {:ok, new_conv} = Store.get_or_create_perpetual_conversation(user.id)
      refute new_conv.id == conv.id
      assert new_conv.status == "active"
    end
  end

  # ---------------------------------------------------------------
  # batch_append_messages/2
  # ---------------------------------------------------------------

  describe "batch_append_messages/2" do
    test "returns {:ok, []} for empty message list" do
      assert {:ok, []} = Store.batch_append_messages(Ecto.UUID.generate(), [])
    end

    test "inserts multiple messages atomically" do
      user = create_test_user()
      {:ok, conv} = Store.create_conversation(%{channel: "test", user_id: user.id})

      messages = [
        %{role: "user", content: "Hello"},
        %{role: "assistant", content: "Hi there!"},
        %{role: "user", content: "How are you?"}
      ]

      assert {:ok, inserted} = Store.batch_append_messages(conv.id, messages)
      assert length(inserted) == 3

      roles = Enum.map(inserted, & &1.role)
      assert roles == ["user", "assistant", "user"]

      contents = Enum.map(inserted, & &1.content)
      assert contents == ["Hello", "Hi there!", "How are you?"]
    end

    test "all messages have correct conversation_id" do
      user = create_test_user()
      {:ok, conv} = Store.create_conversation(%{channel: "test", user_id: user.id})

      messages = [
        %{role: "user", content: "msg1"},
        %{role: "assistant", content: "msg2"}
      ]

      {:ok, inserted} = Store.batch_append_messages(conv.id, messages)

      assert Enum.all?(inserted, fn msg -> msg.conversation_id == conv.id end)
    end

    test "touches conversation last_active_at" do
      user = create_test_user()
      {:ok, conv} = Store.create_conversation(%{channel: "test", user_id: user.id})

      original_active_at = conv.last_active_at
      Process.sleep(10)

      {:ok, _} =
        Store.batch_append_messages(conv.id, [
          %{role: "user", content: "batch msg"}
        ])

      {:ok, updated_conv} = Store.get_conversation(conv.id)

      if original_active_at do
        assert DateTime.compare(updated_conv.last_active_at, original_active_at) == :gt
      else
        assert updated_conv.last_active_at != nil
      end
    end

    test "rolls back entire batch on validation failure" do
      user = create_test_user()
      {:ok, conv} = Store.create_conversation(%{channel: "test", user_id: user.id})

      messages = [
        %{role: "user", content: "valid message"},
        %{role: "invalid_role", content: "this should fail validation"}
      ]

      assert {:error, _} = Store.batch_append_messages(conv.id, messages)

      # No messages should have been inserted (atomic rollback)
      assert Store.list_messages(conv.id) == []
    end

    test "inserts tool_call and tool_result messages" do
      user = create_test_user()
      {:ok, conv} = Store.create_conversation(%{channel: "test", user_id: user.id})

      messages = [
        %{role: "user", content: "Search for X"},
        %{role: "tool_call", tool_calls: %{"name" => "search", "args" => %{"q" => "X"}}},
        %{role: "tool_result", tool_results: %{"result" => "Found X"}},
        %{role: "assistant", content: "I found X for you"}
      ]

      assert {:ok, inserted} = Store.batch_append_messages(conv.id, messages)
      assert length(inserted) == 4

      assert Enum.at(inserted, 1).role == "tool_call"
      assert Enum.at(inserted, 2).role == "tool_result"
    end

    test "works for sub-agent conversations" do
      user = create_test_user()

      {:ok, parent_conv} =
        Store.create_conversation(%{channel: "unified", user_id: user.id})

      {:ok, sub_conv} =
        Store.create_conversation(%{
          channel: "unified",
          user_id: user.id,
          agent_type: "sub_agent",
          parent_conversation_id: parent_conv.id
        })

      messages = [
        %{role: "system", content: "You are a research agent"},
        %{role: "user", content: "Find info about X"},
        %{role: "assistant", content: "Here's what I found about X"}
      ]

      assert {:ok, inserted} = Store.batch_append_messages(sub_conv.id, messages)
      assert length(inserted) == 3
      assert Enum.all?(inserted, fn m -> m.conversation_id == sub_conv.id end)
    end
  end

  # ---------------------------------------------------------------
  # Admin memory access
  # ---------------------------------------------------------------

  describe "list_memory_entries_for_user/4" do
    test "user can access own memories" do
      user = create_test_user()
      {:ok, _} = Store.create_memory_entry(%{content: "my memory", user_id: user.id})

      assert {:ok, entries} =
               Store.list_memory_entries_for_user(user.id, user.id, false)

      assert length(entries) == 1
    end

    test "non-admin cannot access another user's memories" do
      user1 = create_test_user()
      user2 = create_test_user()
      {:ok, _} = Store.create_memory_entry(%{content: "private", user_id: user1.id})

      assert {:error, :unauthorized} =
               Store.list_memory_entries_for_user(user1.id, user2.id, false)
    end

    test "admin can access another user's memories" do
      user1 = create_test_user()
      admin = create_test_user()
      {:ok, _} = Store.create_memory_entry(%{content: "visible to admin", user_id: user1.id})

      assert {:ok, entries} =
               Store.list_memory_entries_for_user(user1.id, admin.id, true)

      assert length(entries) == 1
    end
  end

  describe "list_conversations_for_user/4" do
    test "user can access own conversations" do
      user = create_test_user()
      {:ok, _} = Store.create_conversation(%{channel: "test", user_id: user.id})

      assert {:ok, conversations} =
               Store.list_conversations_for_user(user.id, user.id, false)

      assert length(conversations) == 1
    end

    test "non-admin cannot access another user's conversations" do
      user1 = create_test_user()
      user2 = create_test_user()
      {:ok, _} = Store.create_conversation(%{channel: "test", user_id: user1.id})

      assert {:error, :unauthorized} =
               Store.list_conversations_for_user(user1.id, user2.id, false)
    end

    test "admin can access another user's conversations" do
      user1 = create_test_user()
      admin = create_test_user()
      {:ok, _} = Store.create_conversation(%{channel: "test", user_id: user1.id})

      assert {:ok, conversations} =
               Store.list_conversations_for_user(user1.id, admin.id, true)

      assert length(conversations) == 1
    end
  end

  # ---------------------------------------------------------------
  # Bug 3 regression: FK violation on source_conversation_id
  #
  # When create_memory_entry is called with a source_conversation_id
  # that doesn't exist in the conversations table, Postgres raises a
  # FK constraint error. The changeset includes foreign_key_constraint
  # for :source_conversation_id, so this should return {:error, changeset}
  # rather than raising.
  # ---------------------------------------------------------------

  describe "create_memory_entry/1 with invalid source_conversation_id (Bug 3 regression)" do
    test "returns {:error, changeset} for non-existent source_conversation_id" do
      bogus_id = Ecto.UUID.generate()

      result =
        Store.create_memory_entry(%{
          content: "memory with bad conversation ref",
          source_conversation_id: bogus_id
        })

      assert {:error, %Ecto.Changeset{} = changeset} = result
      assert errors_on(changeset)[:source_conversation_id] != nil
    end

    test "succeeds when source_conversation_id points to a real conversation" do
      user = create_test_user()
      {:ok, conv} = Store.create_conversation(%{channel: "test", user_id: user.id})

      assert {:ok, %MemoryEntry{} = entry} =
               Store.create_memory_entry(%{
                 content: "memory linked to real conversation",
                 source_conversation_id: conv.id,
                 user_id: user.id
               })

      assert entry.source_conversation_id == conv.id
    end

    test "succeeds when source_conversation_id is nil (not linked)" do
      assert {:ok, %MemoryEntry{}} =
               Store.create_memory_entry(%{content: "unlinked memory"})
    end
  end
end
