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
end
