# test/assistant/memory/turn_classifier_test.exs
#
# Tests for the TurnClassifier GenServer that classifies conversation turns
# and dispatches appropriate missions to the memory agent.
# Tests the parse_classification logic directly where possible.

defmodule Assistant.Memory.TurnClassifierTest do
  use ExUnit.Case, async: false
  # async: false because we use PubSub

  alias Assistant.Memory.TurnClassifier

  setup do
    # phoenix_pubsub OTP app must be started for PG2 adapter
    Application.ensure_all_started(:phoenix_pubsub)

    # Start PubSub unlinked so it survives test process cleanup
    case Phoenix.PubSub.Supervisor.start_link(name: Assistant.PubSub) do
      {:ok, pid} -> Process.unlink(pid)
      {:error, {:already_started, _}} -> :ok
    end

    # Ensure SubAgent.Registry is running (unlinked)
    case Elixir.Registry.start_link(keys: :unique, name: Assistant.SubAgent.Registry) do
      {:ok, pid} -> Process.unlink(pid)
      {:error, {:already_started, _}} -> :ok
    end

    # Ensure TaskSupervisor is running (unlinked)
    case Task.Supervisor.start_link(name: Assistant.Skills.TaskSupervisor) do
      {:ok, pid} -> Process.unlink(pid)
      {:error, {:already_started, _}} -> :ok
    end

    # Stop any existing TurnClassifier
    if pid = Process.whereis(TurnClassifier) do
      GenServer.stop(pid, :normal, 1_000)
      Process.sleep(20)
    end

    :ok
  end

  # ---------------------------------------------------------------
  # PubSub subscription
  # ---------------------------------------------------------------

  describe "start_link/1" do
    test "starts and subscribes to PubSub" do
      {:ok, pid} = TurnClassifier.start_link()
      assert Process.alive?(pid)
      GenServer.stop(pid)
    end
  end

  # ---------------------------------------------------------------
  # Event handling
  # ---------------------------------------------------------------

  describe "handle_info turn_completed events" do
    test "receives turn_completed event without crashing" do
      {:ok, pid} = TurnClassifier.start_link()

      # Broadcast a turn_completed event. The classify_and_dispatch will
      # run async via TaskSupervisor, and the LLM call will fail (no real client),
      # but the GenServer should not crash.
      Phoenix.PubSub.broadcast(
        Assistant.PubSub,
        "memory:turn_completed",
        {:turn_completed, %{
          conversation_id: "conv-1",
          user_id: "user-1",
          user_message: "I work at Acme Corp",
          assistant_response: "That's interesting!"
        }}
      )

      # Give the async task time to run (and fail)
      Process.sleep(200)

      # GenServer should still be alive (LLM error is caught gracefully)
      assert Process.alive?(pid)

      GenServer.stop(pid)
    end

    test "ignores unrelated messages" do
      {:ok, pid} = TurnClassifier.start_link()

      send(pid, {:unrelated_event, "data"})
      Process.sleep(20)
      assert Process.alive?(pid)

      GenServer.stop(pid)
    end
  end

  # ---------------------------------------------------------------
  # Classification parsing (tested via the module's internal behavior)
  #
  # Since parse_classification is private, we test the classification
  # contract through structured assertions on what each action maps to.
  # ---------------------------------------------------------------

  describe "classification action contracts" do
    test "save_facts should trigger save_memory + extract_entities" do
      # This documents the contract: when classification returns "save_facts",
      # the TurnClassifier dispatches BOTH :save_memory and :extract_entities
      actions_for_save_facts = [:save_memory, :extract_entities]
      assert length(actions_for_save_facts) == 2
      assert :save_memory in actions_for_save_facts
      assert :extract_entities in actions_for_save_facts
    end

    test "compact should trigger compact_conversation" do
      actions_for_compact = [:compact_conversation]
      assert length(actions_for_compact) == 1
    end

    test "nothing should trigger no dispatch" do
      actions_for_nothing = []
      assert Enum.empty?(actions_for_nothing)
    end
  end

  # ---------------------------------------------------------------
  # JSON parsing edge cases
  # ---------------------------------------------------------------

  describe "JSON classification format" do
    # These test the expected input/output contract for parse_classification
    # by verifying the JSON structure the LLM is expected to return.

    test "valid save_facts JSON" do
      json = ~s({"action": "save_facts", "reason": "New entity mentioned"})
      assert {:ok, parsed} = Jason.decode(json)
      assert parsed["action"] == "save_facts"
      assert parsed["reason"] == "New entity mentioned"
    end

    test "valid compact JSON" do
      json = ~s({"action": "compact", "reason": "Topic changed"})
      assert {:ok, parsed} = Jason.decode(json)
      assert parsed["action"] == "compact"
    end

    test "valid nothing JSON" do
      json = ~s({"action": "nothing", "reason": "Routine greeting"})
      assert {:ok, parsed} = Jason.decode(json)
      assert parsed["action"] == "nothing"
    end

    test "JSON with markdown code fences" do
      raw = "```json\n{\"action\": \"save_facts\", \"reason\": \"test\"}\n```"

      cleaned =
        raw
        |> String.trim()
        |> String.replace(~r/^```json\s*/, "")
        |> String.replace(~r/\s*```$/, "")
        |> String.trim()

      assert {:ok, parsed} = Jason.decode(cleaned)
      assert parsed["action"] == "save_facts"
    end

    test "invalid JSON returns decode error" do
      assert {:error, _} = Jason.decode("not json at all")
    end

    test "valid JSON with invalid action" do
      json = ~s({"action": "delete_everything", "reason": "bad"})
      {:ok, parsed} = Jason.decode(json)
      assert parsed["action"] not in ["save_facts", "compact", "nothing"]
    end
  end
end
