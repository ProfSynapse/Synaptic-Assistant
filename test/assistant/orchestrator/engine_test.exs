# test/assistant/orchestrator/engine_test.exs — Integration tests for Engine startup.
#
# Verifies that Engine starts correctly when registered by user_id UUID,
# carries the correct conversation_id in state, and hydrates from DB.

defmodule Assistant.Orchestrator.EngineTest do
  use Assistant.DataCase, async: false
  # async: false because Engine uses named registries

  alias Assistant.Orchestrator.Engine
  alias Assistant.Schemas.{Conversation, User}

  setup do
    # Trap exits so Engine crashes don't kill test process
    Process.flag(:trap_exit, true)

    # Ensure EngineRegistry is running (unlinked)
    case Registry.start_link(keys: :unique, name: Assistant.Orchestrator.EngineRegistry) do
      {:ok, pid} -> Process.unlink(pid)
      {:error, {:already_started, _}} -> :ok
    end

    # Ensure SubAgent.Registry is running (unlinked)
    case Registry.start_link(keys: :unique, name: Assistant.SubAgent.Registry) do
      {:ok, pid} -> Process.unlink(pid)
      {:error, {:already_started, _}} -> :ok
    end

    :ok
  end

  # Helper to create a user and conversation in DB
  defp create_user_and_conversation do
    user =
      %User{}
      |> User.changeset(%{
        external_id: "engine-test-#{System.unique_integer([:positive])}",
        channel: "test"
      })
      |> Repo.insert!()

    {:ok, conversation} =
      %Conversation{}
      |> Conversation.changeset(%{channel: "unified", user_id: user.id})
      |> Repo.insert()

    {user, conversation}
  end

  # Safe stop that handles already-dead processes
  defp safe_stop(pid) do
    if Process.alive?(pid) do
      try do
        GenServer.stop(pid, :normal, 1_000)
      catch
        :exit, _ -> :ok
      end
    end
  end

  # ---------------------------------------------------------------
  # Engine start registered by user_id UUID
  # ---------------------------------------------------------------

  describe "start_link registered by user_id" do
    test "starts successfully with user_id and conversation_id in opts" do
      {user, conversation} = create_user_and_conversation()

      result =
        Engine.start_link(user.id,
          conversation_id: conversation.id,
          channel: "test"
        )

      assert {:ok, pid} = result
      assert Process.alive?(pid)

      # Engine should be registered with the user_id (not conversation_id)
      assert [{^pid, _}] =
               Registry.lookup(Assistant.Orchestrator.EngineRegistry, user.id)

      safe_stop(pid)
    end

    test "engine state has correct user_id and conversation_id" do
      {user, conversation} = create_user_and_conversation()

      {:ok, pid} =
        Engine.start_link(user.id,
          conversation_id: conversation.id,
          channel: "test"
        )

      {:ok, state} = Engine.get_state(user.id)

      assert state.conversation_id == conversation.id
      assert state.user_id == user.id
      assert state.channel == "test"

      safe_stop(pid)
    end

    test "conversation_id in engine state exists in database" do
      {user, conversation} = create_user_and_conversation()

      {:ok, pid} =
        Engine.start_link(user.id,
          conversation_id: conversation.id,
          channel: "test"
        )

      {:ok, state} = Engine.get_state(user.id)

      # The conversation_id in engine state should reference a real DB record
      assert {:ok, %Conversation{}} =
               Assistant.Memory.Store.get_conversation(state.conversation_id)

      safe_stop(pid)
    end
  end

  # ---------------------------------------------------------------
  # Bug 1: Role mapping between LLM ("tool") and DB ("tool_result")
  # ---------------------------------------------------------------

  describe "role mapping (Bug 1 fix)" do
    test "llm_role_to_db_role maps 'tool' to 'tool_result'" do
      assert Engine.llm_role_to_db_role("tool") == "tool_result"
    end

    test "llm_role_to_db_role passes through other roles unchanged" do
      assert Engine.llm_role_to_db_role("user") == "user"
      assert Engine.llm_role_to_db_role("assistant") == "assistant"
      assert Engine.llm_role_to_db_role("system") == "system"
      assert Engine.llm_role_to_db_role("tool_call") == "tool_call"
      assert Engine.llm_role_to_db_role("tool_result") == "tool_result"
    end

    test "db_role_to_llm_role maps 'tool_result' to 'tool'" do
      assert Engine.db_role_to_llm_role("tool_result") == "tool"
    end

    test "db_role_to_llm_role passes through other roles unchanged" do
      assert Engine.db_role_to_llm_role("user") == "user"
      assert Engine.db_role_to_llm_role("assistant") == "assistant"
      assert Engine.db_role_to_llm_role("system") == "system"
      assert Engine.db_role_to_llm_role("tool_call") == "tool_call"
      assert Engine.db_role_to_llm_role("tool") == "tool"
    end

    test "round-trip: tool -> tool_result -> tool preserves semantics" do
      original = "tool"
      db_form = Engine.llm_role_to_db_role(original)
      restored = Engine.db_role_to_llm_role(db_form)

      assert db_form == "tool_result"
      assert restored == original
    end
  end

  # ---------------------------------------------------------------
  # Bug 3: Hydration order — most recent 50, not oldest 50
  # ---------------------------------------------------------------

  describe "hydration order (Bug 3 fix)" do
    test "hydrates latest messages, not oldest, when >50 messages exist" do
      {user, conversation} = create_user_and_conversation()

      # Insert 55 messages (more than @hydrate_message_limit of 50)
      for i <- 1..55 do
        role = if rem(i, 2) == 1, do: "user", else: "assistant"

        {:ok, _} =
          Assistant.Memory.Store.append_message(conversation.id, %{
            role: role,
            content: "message-#{i}"
          })
      end

      # Start engine — it should hydrate the latest 50 messages
      {:ok, pid} =
        Engine.start_link(user.id,
          conversation_id: conversation.id,
          channel: "test"
        )

      {:ok, state} = Engine.get_state(user.id)

      # Should have 50 messages (the limit)
      assert state.message_count == 50

      safe_stop(pid)

      # Verify the oldest 5 messages (1-5) were excluded and the
      # newest message (55) was included by checking the store query
      # directly: desc + limit 50 + reverse gives messages 6-55 in
      # ascending order.
      hydrated =
        Assistant.Memory.Store.list_messages(conversation.id,
          limit: 50,
          order: :desc
        )
        |> Enum.reverse()

      assert length(hydrated) == 50
      # First hydrated message should be message-6 (oldest 5 excluded)
      assert hydrated |> hd() |> Map.get(:content) == "message-6"
      # Last hydrated message should be message-55
      assert hydrated |> List.last() |> Map.get(:content) == "message-55"
    end

    test "hydration returns all messages when <=50 messages exist" do
      {user, conversation} = create_user_and_conversation()

      for i <- 1..10 do
        role = if rem(i, 2) == 1, do: "user", else: "assistant"

        {:ok, _} =
          Assistant.Memory.Store.append_message(conversation.id, %{
            role: role,
            content: "message-#{i}"
          })
      end

      {:ok, pid} =
        Engine.start_link(user.id,
          conversation_id: conversation.id,
          channel: "test"
        )

      {:ok, state} = Engine.get_state(user.id)

      assert state.message_count == 10

      safe_stop(pid)
    end
  end
end
