defmodule Assistant.Orchestrator.Tools.QuerySubagentTest do
  use ExUnit.Case, async: false

  alias Assistant.Orchestrator.Tools.QuerySubagent

  setup do
    case Registry.start_link(keys: :unique, name: Assistant.SubAgent.Registry) do
      {:ok, pid} -> Process.unlink(pid)
      {:error, {:already_started, _}} -> :ok
    end

    :ok
  end

  describe "tool_definition/0" do
    test "returns a valid tool definition map" do
      defn = QuerySubagent.tool_definition()

      assert defn.name == "query_subagent"
      assert defn.parameters["required"] == ["agent_id", "question"]
      assert Map.has_key?(defn.parameters["properties"], "agent_id")
      assert Map.has_key?(defn.parameters["properties"], "question")
    end
  end

  describe "execute/2 validation" do
    test "returns error when agent_id is missing" do
      {:ok, result} = QuerySubagent.execute(%{"question" => "What is happening?"}, %{})

      assert result.status == :error
      assert result.content =~ "agent_id"
    end

    test "returns error when question is missing" do
      {:ok, result} = QuerySubagent.execute(%{"agent_id" => "agent-1"}, %{})

      assert result.status == :error
      assert result.content =~ "question"
    end

    test "returns not found when no snapshot is available" do
      {:ok, result} =
        QuerySubagent.execute(
          %{"agent_id" => "missing-agent", "question" => "What has it learned?"},
          %{dispatched_agents: %{}}
        )

      assert result.status == :error
      assert result.content =~ "not found"
    end
  end
end
