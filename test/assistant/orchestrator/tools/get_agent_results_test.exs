# test/assistant/orchestrator/tools/get_agent_results_test.exs
#
# Tests for the GetAgentResults meta-tool (agent result collection).
# Tests execute/2 with various dispatched_agents state maps and modes.

defmodule Assistant.Orchestrator.Tools.GetAgentResultsTest do
  use ExUnit.Case, async: true

  alias Assistant.Orchestrator.Tools.GetAgentResults

  # ---------------------------------------------------------------
  # tool_definition/0
  # ---------------------------------------------------------------

  describe "tool_definition/0" do
    test "returns a valid tool definition map" do
      defn = GetAgentResults.tool_definition()

      assert defn.name == "get_agent_results"
      assert is_binary(defn.description)
      assert defn.parameters["type"] == "object"
      assert Map.has_key?(defn.parameters["properties"], "agent_ids")
      assert Map.has_key?(defn.parameters["properties"], "mode")
    end
  end

  # ---------------------------------------------------------------
  # execute/2 — non_blocking mode
  # ---------------------------------------------------------------

  describe "execute/2 non_blocking with completed agents" do
    test "returns results for completed agent" do
      dispatched = %{
        "agent_1" => %{
          status: :completed,
          result: "Found 3 emails.",
          tool_calls_used: 2,
          duration_ms: 500
        }
      }

      {:ok, result} = GetAgentResults.execute(%{"agent_ids" => ["agent_1"]}, dispatched)

      assert result.status == :ok
      assert result.content =~ "agent_1"
      assert result.content =~ "completed"
      assert result.metadata.done == true
      assert result.metadata.completed == 1
      assert result.metadata.total == 1
    end

    test "returns results for failed agent" do
      dispatched = %{
        "agent_1" => %{
          status: :failed,
          result: "LLM call failed.",
          tool_calls_used: 0,
          duration_ms: 100
        }
      }

      {:ok, result} = GetAgentResults.execute(%{"agent_ids" => ["agent_1"]}, dispatched)

      assert result.status == :ok
      assert result.content =~ "failed"
      assert result.metadata.failed == 1
    end

    test "returns 'not found' for unknown agent_id" do
      dispatched = %{}

      {:ok, result} = GetAgentResults.execute(%{"agent_ids" => ["unknown_agent"]}, dispatched)

      assert result.status == :ok
      assert result.content =~ "No agent found"
    end

    test "returns all agents when no agent_ids specified" do
      dispatched = %{
        "agent_a" => %{status: :completed, result: "Done A"},
        "agent_b" => %{status: :running, result: nil}
      }

      {:ok, result} = GetAgentResults.execute(%{}, dispatched)

      assert result.metadata.total == 2
      assert result.metadata.done == false
    end

    test "handles empty dispatched_agents map" do
      {:ok, result} = GetAgentResults.execute(%{}, %{})

      assert result.status == :ok
      assert result.metadata.total == 0
      assert result.metadata.done == true
    end
  end

  # ---------------------------------------------------------------
  # execute/2 — running agents
  # ---------------------------------------------------------------

  describe "execute/2 non_blocking with running agents" do
    test "shows running status" do
      dispatched = %{
        "agent_1" => %{status: :running, result: nil}
      }

      {:ok, result} = GetAgentResults.execute(%{"agent_ids" => ["agent_1"]}, dispatched)

      assert result.content =~ "running"
      assert result.metadata.done == false
    end

    test "shows pending status" do
      dispatched = %{
        "agent_1" => %{status: :pending}
      }

      {:ok, result} = GetAgentResults.execute(%{"agent_ids" => ["agent_1"]}, dispatched)

      assert result.content =~ "pending"
      assert result.metadata.done == false
    end
  end

  # ---------------------------------------------------------------
  # execute/2 — awaiting_orchestrator
  # ---------------------------------------------------------------

  describe "execute/2 with awaiting_orchestrator agent" do
    test "shows awaiting status with reason" do
      dispatched = %{
        "agent_1" => %{
          status: :awaiting_orchestrator,
          reason: "Need email credentials",
          result: nil,
          partial_history: ["Step 1: searched for emails"]
        }
      }

      {:ok, result} = GetAgentResults.execute(%{"agent_ids" => ["agent_1"]}, dispatched)

      assert result.content =~ "awaiting"
      assert result.content =~ "Need email credentials"
      assert result.metadata.awaiting == 1
    end
  end

  # ---------------------------------------------------------------
  # execute/2 — wait_any mode
  # ---------------------------------------------------------------

  describe "execute/2 wait_any mode" do
    test "returns immediately if all agents already terminal" do
      dispatched = %{
        "agent_1" => %{status: :completed, result: "Done"}
      }

      {:ok, result} =
        GetAgentResults.execute(
          %{"agent_ids" => ["agent_1"], "mode" => "wait_any"},
          dispatched
        )

      assert result.status == :ok
      assert result.metadata.done == true
    end

    test "returns {:wait, ...} when agents still running" do
      dispatched = %{
        "agent_1" => %{status: :running, result: nil}
      }

      result =
        GetAgentResults.execute(
          %{"agent_ids" => ["agent_1"], "mode" => "wait_any"},
          dispatched
        )

      assert {:wait, :wait_any, timeout_ms, ["agent_1"]} = result
      assert is_integer(timeout_ms)
    end

    test "uses custom wait_ms" do
      dispatched = %{
        "agent_1" => %{status: :running, result: nil}
      }

      {:wait, :wait_any, timeout_ms, _} =
        GetAgentResults.execute(
          %{"agent_ids" => ["agent_1"], "mode" => "wait_any", "wait_ms" => 10000},
          dispatched
        )

      assert timeout_ms == 10000
    end

    test "clamps wait_ms to max" do
      dispatched = %{
        "agent_1" => %{status: :running, result: nil}
      }

      {:wait, :wait_any, timeout_ms, _} =
        GetAgentResults.execute(
          %{"agent_ids" => ["agent_1"], "mode" => "wait_any", "wait_ms" => 999_999},
          dispatched
        )

      # Max is 60_000
      assert timeout_ms == 60_000
    end
  end

  # ---------------------------------------------------------------
  # execute/2 — wait_all mode
  # ---------------------------------------------------------------

  describe "execute/2 wait_all mode" do
    test "returns immediately if all agents terminal" do
      dispatched = %{
        "agent_1" => %{status: :completed, result: "Done 1"},
        "agent_2" => %{status: :failed, result: "Error"}
      }

      {:ok, result} =
        GetAgentResults.execute(
          %{"agent_ids" => ["agent_1", "agent_2"], "mode" => "wait_all"},
          dispatched
        )

      assert result.metadata.done == true
    end

    test "returns {:wait, ...} when some agents not terminal" do
      dispatched = %{
        "agent_1" => %{status: :completed, result: "Done"},
        "agent_2" => %{status: :running, result: nil}
      }

      {:wait, :wait_all, _, agent_ids} =
        GetAgentResults.execute(
          %{"agent_ids" => ["agent_1", "agent_2"], "mode" => "wait_all"},
          dispatched
        )

      assert "agent_1" in agent_ids
      assert "agent_2" in agent_ids
    end
  end

  # ---------------------------------------------------------------
  # execute/2 — transcript tail
  # ---------------------------------------------------------------

  describe "execute/2 with transcript tail" do
    test "includes transcript tail when requested" do
      dispatched = %{
        "agent_1" => %{
          status: :running,
          result: nil,
          transcript_tail: ["Line 1", "Line 2", "Line 3"]
        }
      }

      {:ok, result} =
        GetAgentResults.execute(
          %{
            "agent_ids" => ["agent_1"],
            "include_transcript_tail" => true,
            "tail_lines" => 2
          },
          dispatched
        )

      # The tail is in the metadata agents list
      agent_data = Enum.find(result.metadata.agents, &(&1.agent_id == "agent_1"))
      assert is_list(agent_data.transcript_tail)
    end
  end

  # ---------------------------------------------------------------
  # format_after_wait/4
  # ---------------------------------------------------------------

  describe "format_after_wait/4" do
    test "formats results after wait completes" do
      dispatched = %{
        "agent_1" => %{status: :completed, result: "All done!"}
      }

      {:ok, result} = GetAgentResults.format_after_wait(%{"agent_ids" => ["agent_1"]}, dispatched)

      assert result.status == :ok
      assert result.content =~ "agent_1"
      assert result.metadata.done == true
    end
  end

  # ---------------------------------------------------------------
  # Mixed scenarios
  # ---------------------------------------------------------------

  describe "execute/2 with mixed agent states" do
    test "correctly counts completed, failed, and running" do
      dispatched = %{
        "a" => %{status: :completed, result: "OK"},
        "b" => %{status: :failed, result: "Error"},
        "c" => %{status: :running, result: nil},
        "d" => %{status: :timeout, result: "Timed out"}
      }

      {:ok, result} = GetAgentResults.execute(%{}, dispatched)

      assert result.metadata.total == 4
      assert result.metadata.completed == 1
      # failed + timeout
      assert result.metadata.failed == 2
      # "c" is still running
      assert result.metadata.done == false
    end
  end
end
