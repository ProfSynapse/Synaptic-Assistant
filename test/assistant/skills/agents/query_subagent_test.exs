defmodule Assistant.Skills.Agents.QuerySubagentTest do
  use ExUnit.Case, async: true

  alias Assistant.Skills.Registry

  test "agents.query_subagent is registered in the skills registry" do
    assert Registry.skill_exists?("agents.query_subagent")

    assert {:ok, skill} = Registry.lookup("agents.query_subagent")
    assert skill.domain == "agents"
    assert skill.handler == Assistant.Skills.Agents.QuerySubagent
    assert Enum.any?(skill.parameters, &(&1.name == "agent_id" and &1.required))
    assert Enum.any?(skill.parameters, &(&1.name == "question" and &1.required))
  end
end
