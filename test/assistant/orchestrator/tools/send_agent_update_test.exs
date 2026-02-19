# test/assistant/orchestrator/tools/send_agent_update_test.exs
#
# Tests for the SendAgentUpdate meta-tool (orchestrator→sub-agent updates).
# Tests validation logic and error paths. Success path requires a running
# SubAgent GenServer, so we test the not_found case via the Registry.

defmodule Assistant.Orchestrator.Tools.SendAgentUpdateTest do
  use ExUnit.Case, async: false
  # async: false because SubAgent.resume uses named Registry

  alias Assistant.Orchestrator.Tools.SendAgentUpdate

  setup do
    # Ensure the SubAgent Registry is running
    case Registry.start_link(keys: :unique, name: Assistant.SubAgent.Registry) do
      {:ok, pid} -> Process.unlink(pid)
      {:error, {:already_started, _}} -> :ok
    end

    :ok
  end

  # ---------------------------------------------------------------
  # tool_definition/0
  # ---------------------------------------------------------------

  describe "tool_definition/0" do
    test "returns a valid tool definition map" do
      defn = SendAgentUpdate.tool_definition()

      assert defn.name == "send_agent_update"
      assert is_binary(defn.description)
      assert defn.parameters["type"] == "object"
      assert Map.has_key?(defn.parameters["properties"], "agent_id")
      assert Map.has_key?(defn.parameters["properties"], "message")
      assert defn.parameters["required"] == ["agent_id"]
    end
  end

  # ---------------------------------------------------------------
  # execute/2 — validation errors
  # ---------------------------------------------------------------

  describe "execute/2 validation" do
    test "returns error when agent_id is missing" do
      {:ok, result} = SendAgentUpdate.execute(%{}, nil)

      assert result.status == :error
      assert result.content =~ "agent_id"
    end

    test "returns error when agent_id is empty string" do
      {:ok, result} = SendAgentUpdate.execute(%{"agent_id" => ""}, nil)

      assert result.status == :error
      assert result.content =~ "agent_id"
    end

    test "returns error when no update content provided" do
      {:ok, result} = SendAgentUpdate.execute(%{"agent_id" => "test_agent"}, nil)

      assert result.status == :error
      assert result.content =~ "At least one of"
    end

    test "returns error when all update fields are empty" do
      params = %{
        "agent_id" => "test_agent",
        "message" => "",
        "skills" => [],
        "context_files" => []
      }

      {:ok, result} = SendAgentUpdate.execute(params, nil)

      assert result.status == :error
      assert result.content =~ "At least one of"
    end
  end

  # ---------------------------------------------------------------
  # execute/2 — agent not found
  # ---------------------------------------------------------------

  describe "execute/2 agent not found" do
    test "returns error when agent is not registered" do
      params = %{
        "agent_id" => "nonexistent_agent_xyz",
        "message" => "Here's your update"
      }

      {:ok, result} = SendAgentUpdate.execute(params, nil)

      assert result.status == :error
      assert result.content =~ "not found"
    end
  end
end
