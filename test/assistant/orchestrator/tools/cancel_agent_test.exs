# test/assistant/orchestrator/tools/cancel_agent_test.exs
#
# Tests for the CancelAgent meta-tool (orchestrator hard-stop).

defmodule Assistant.Orchestrator.Tools.CancelAgentTest do
  use ExUnit.Case, async: false

  alias Assistant.Orchestrator.Tools.CancelAgent

  setup do
    case Registry.start_link(keys: :unique, name: Assistant.SubAgent.Registry) do
      {:ok, pid} -> Process.unlink(pid)
      {:error, {:already_started, _}} -> :ok
    end

    :ok
  end

  describe "tool_definition/0" do
    test "returns a valid tool definition map" do
      defn = CancelAgent.tool_definition()

      assert defn.name == "cancel_agent"
      assert is_binary(defn.description)
      assert defn.parameters["type"] == "object"
      assert Map.has_key?(defn.parameters["properties"], "agent_id")
      assert Map.has_key?(defn.parameters["properties"], "reason")
      assert defn.parameters["required"] == ["agent_id"]
    end
  end

  describe "execute/2" do
    test "returns validation error when agent_id is missing" do
      {:ok, result} = CancelAgent.execute(%{}, nil)

      assert result.status == :error
      assert result.content =~ "agent_id"
    end

    test "returns not found when the agent is not registered" do
      {:ok, result} = CancelAgent.execute(%{"agent_id" => "missing-agent"}, nil)

      assert result.status == :error
      assert result.content =~ "not found"
    end
  end
end
