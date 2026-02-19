# test/assistant/orchestrator/tools/dispatch_agent_test.exs
#
# Tests for the DispatchAgent meta-tool (sub-agent dispatch).
# Tests validation logic and tool_definition. The success path
# requires Ecto Repo (DB) for ExecutionLog creation, so we focus
# on validation error paths that return before DB access.

defmodule Assistant.Orchestrator.Tools.DispatchAgentTest do
  use ExUnit.Case, async: false
  # async: false because we use named ETS (Skills.Registry)

  alias Assistant.Orchestrator.Tools.DispatchAgent

  setup do
    ensure_skills_registry_started()
    :ok
  end

  # ---------------------------------------------------------------
  # tool_definition/0
  # ---------------------------------------------------------------

  describe "tool_definition/0" do
    test "returns a valid tool definition map" do
      defn = DispatchAgent.tool_definition()

      assert defn.name == "dispatch_agent"
      assert is_binary(defn.description)
      assert defn.parameters["type"] == "object"
      assert Map.has_key?(defn.parameters["properties"], "agent_id")
      assert Map.has_key?(defn.parameters["properties"], "mission")
      assert Map.has_key?(defn.parameters["properties"], "skills")
      assert defn.parameters["required"] == ["agent_id", "mission", "skills"]
    end
  end

  # ---------------------------------------------------------------
  # execute/2 — missing required fields
  # ---------------------------------------------------------------

  describe "execute/2 missing fields" do
    test "returns error when all required fields missing" do
      context = %Assistant.Skills.Context{
        conversation_id: "conv-1",
        execution_id: "exec-1",
        user_id: "user-1"
      }

      {:ok, result} = DispatchAgent.execute(%{}, context)

      assert result.status == :error
      assert result.content =~ "Missing required fields"
    end

    test "returns error when agent_id is missing" do
      context = %Assistant.Skills.Context{
        conversation_id: "conv-1",
        execution_id: "exec-1",
        user_id: "user-1"
      }

      params = %{
        "mission" => "Search for emails",
        "skills" => ["email.search"]
      }

      {:ok, result} = DispatchAgent.execute(params, context)

      assert result.status == :error
      assert result.content =~ "agent_id"
    end

    test "returns error when mission is empty string" do
      context = %Assistant.Skills.Context{
        conversation_id: "conv-1",
        execution_id: "exec-1",
        user_id: "user-1"
      }

      params = %{
        "agent_id" => "test_agent",
        "mission" => "",
        "skills" => ["email.search"]
      }

      {:ok, result} = DispatchAgent.execute(params, context)

      assert result.status == :error
      assert result.content =~ "Missing required fields"
    end

    test "returns error when skills is empty list" do
      context = %Assistant.Skills.Context{
        conversation_id: "conv-1",
        execution_id: "exec-1",
        user_id: "user-1"
      }

      params = %{
        "agent_id" => "test_agent",
        "mission" => "Do something",
        "skills" => []
      }

      {:ok, result} = DispatchAgent.execute(params, context)

      assert result.status == :error
      assert result.content =~ "Missing required fields"
    end
  end

  # ---------------------------------------------------------------
  # execute/2 — unknown skills
  # ---------------------------------------------------------------

  describe "execute/2 unknown skills" do
    test "returns error when skills don't exist in registry" do
      context = %Assistant.Skills.Context{
        conversation_id: "conv-1",
        execution_id: "exec-1",
        user_id: "user-1"
      }

      params = %{
        "agent_id" => "test_agent",
        "mission" => "Search emails",
        "skills" => ["nonexistent.skill"]
      }

      {:ok, result} = DispatchAgent.execute(params, context)

      assert result.status == :error
      assert result.content =~ "Unknown skills"
      assert result.content =~ "nonexistent.skill"
    end
  end

  # ---------------------------------------------------------------
  # check_dispatch_limit/2
  # ---------------------------------------------------------------

  describe "check_dispatch_limit/2" do
    test "allows first dispatch within limit" do
      turn_state = Assistant.Resilience.CircuitBreaker.new_turn_state()
      assert {:ok, _updated} = DispatchAgent.check_dispatch_limit(turn_state, 1)
    end
  end

  # ---------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------

  defp ensure_skills_registry_started do
    if :ets.whereis(:assistant_skills) != :undefined do
      :ok
    else
      tmp_dir =
        Path.join(System.tmp_dir!(), "empty_skills_da_#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp_dir)

      case Assistant.Skills.Registry.start_link(skills_dir: tmp_dir) do
        {:ok, _} -> :ok
        {:error, {:already_started, _}} -> :ok
      end
    end
  end
end
