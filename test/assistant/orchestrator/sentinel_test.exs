# test/assistant/orchestrator/sentinel_test.exs
#
# Tests for the Sentinel security gate (Phase 1 stub).
# Verifies the contract is maintained and that the stub always approves.

defmodule Assistant.Orchestrator.SentinelTest do
  use ExUnit.Case, async: true

  alias Assistant.Orchestrator.Sentinel

  describe "check/3 (Phase 1 stub)" do
    test "always returns approved for any action" do
      proposed_action = %{
        skill_name: "email.send",
        arguments: %{"to" => "bob@co.com"},
        agent_id: "agent_1"
      }

      assert {:ok, :approved} =
               Sentinel.check("Send an email to Bob", "Send email", proposed_action)
    end

    test "handles nil original request" do
      proposed_action = %{
        skill_name: "tasks.create",
        arguments: %{"title" => "New task"},
        agent_id: "agent_2"
      }

      assert {:ok, :approved} = Sentinel.check(nil, "Create a task", proposed_action)
    end

    test "handles empty mission" do
      proposed_action = %{
        skill_name: "memory.save",
        arguments: %{},
        agent_id: "agent_3"
      }

      assert {:ok, :approved} = Sentinel.check("Save something", "", proposed_action)
    end

    test "handles very long text (truncation)" do
      long_request = String.duplicate("x", 1000)
      long_mission = String.duplicate("y", 1000)

      proposed_action = %{
        skill_name: "files.write",
        arguments: %{"path" => "/tmp/test"},
        agent_id: "agent_4"
      }

      # Should not crash on long text
      assert {:ok, :approved} = Sentinel.check(long_request, long_mission, proposed_action)
    end

    test "returns correct tuple shape for all cases" do
      # Ensure the return type matches the spec
      result =
        Sentinel.check("req", "mission", %{
          skill_name: "any.skill",
          arguments: %{},
          agent_id: "a"
        })

      assert {:ok, :approved} = result
    end
  end
end
