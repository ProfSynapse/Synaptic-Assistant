# test/assistant/orchestrator/engine_test.exs — Integration tests for Engine startup.
#
# Bug 3 regression: Engine.start_link with a UUID conversation_id (from DB)
# should start successfully. Previously, when the orchestrator started with
# a real DB conversation_id, sub-agents would use a non-existent sub_conversation_id
# for memory saves, causing FK violations. These tests verify the engine starts
# correctly with DB-backed conversation IDs.

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
      |> Conversation.changeset(%{channel: "test", user_id: user.id})
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
  # Engine start with UUID conversation_id (Bug 3 regression)
  # ---------------------------------------------------------------

  describe "start_link with DB-backed conversation_id (Bug 3 regression)" do
    test "starts successfully with a real UUID conversation_id" do
      {user, conversation} = create_user_and_conversation()

      result =
        Engine.start_link(conversation.id,
          user_id: user.id,
          channel: "test"
        )

      assert {:ok, pid} = result
      assert Process.alive?(pid)

      # Engine should be registered with the conversation_id
      assert [{^pid, _}] =
               Registry.lookup(Assistant.Orchestrator.EngineRegistry, conversation.id)

      safe_stop(pid)
    end

    test "engine state has correct conversation_id" do
      {user, conversation} = create_user_and_conversation()

      {:ok, pid} = Engine.start_link(conversation.id, user_id: user.id, channel: "test")

      {:ok, state} = Engine.get_state(conversation.id)

      assert state.conversation_id == conversation.id
      assert state.user_id == user.id
      assert state.channel == "test"

      safe_stop(pid)
    end

    test "conversation_id in engine state exists in database" do
      {user, conversation} = create_user_and_conversation()

      {:ok, pid} = Engine.start_link(conversation.id, user_id: user.id, channel: "test")
      {:ok, state} = Engine.get_state(conversation.id)

      # The conversation_id in engine state should reference a real DB record
      assert {:ok, %Conversation{}} =
               Assistant.Memory.Store.get_conversation(state.conversation_id)

      safe_stop(pid)
    end
  end
end
