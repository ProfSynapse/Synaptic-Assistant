# test/assistant/orchestrator/agent_scheduler_test.exs
#
# Tests for DAG-based execution scheduling via Kahn's algorithm.
# Pure logic tests — no GenServer, no mocks needed for plan_waves/1.

defmodule Assistant.Orchestrator.AgentSchedulerTest do
  use ExUnit.Case, async: true

  alias Assistant.Orchestrator.AgentScheduler

  # ---------------------------------------------------------------
  # plan_waves/1 — Dependency Resolution
  # ---------------------------------------------------------------

  describe "plan_waves/1" do
    test "returns empty waves for empty dispatches" do
      assert {:ok, []} = AgentScheduler.plan_waves(%{})
    end

    test "single agent with no dependencies produces one wave" do
      dispatches = %{
        "agent_a" => %{mission: "do something", skills: ["email.send"]}
      }

      assert {:ok, [["agent_a"]]} = AgentScheduler.plan_waves(dispatches)
    end

    test "two independent agents are in the same wave" do
      dispatches = %{
        "agent_a" => %{mission: "task a", skills: ["email.send"]},
        "agent_b" => %{mission: "task b", skills: ["tasks.search"]}
      }

      assert {:ok, [wave_0]} = AgentScheduler.plan_waves(dispatches)
      assert Enum.sort(wave_0) == ["agent_a", "agent_b"]
    end

    test "serial dependency produces two waves" do
      dispatches = %{
        "agent_a" => %{mission: "first", skills: ["email.search"]},
        "agent_b" => %{mission: "second", skills: ["email.send"], depends_on: ["agent_a"]}
      }

      assert {:ok, [wave_0, wave_1]} = AgentScheduler.plan_waves(dispatches)
      assert wave_0 == ["agent_a"]
      assert wave_1 == ["agent_b"]
    end

    test "diamond dependency graph produces correct waves" do
      #      A
      #     / \
      #    B   C
      #     \ /
      #      D
      dispatches = %{
        "a" => %{mission: "root", skills: ["s1"]},
        "b" => %{mission: "left", skills: ["s2"], depends_on: ["a"]},
        "c" => %{mission: "right", skills: ["s3"], depends_on: ["a"]},
        "d" => %{mission: "join", skills: ["s4"], depends_on: ["b", "c"]}
      }

      assert {:ok, waves} = AgentScheduler.plan_waves(dispatches)
      assert length(waves) == 3

      [wave_0, wave_1, wave_2] = waves
      assert wave_0 == ["a"]
      assert Enum.sort(wave_1) == ["b", "c"]
      assert wave_2 == ["d"]
    end

    test "three-level chain A -> B -> C" do
      dispatches = %{
        "a" => %{mission: "first", skills: ["s1"]},
        "b" => %{mission: "second", skills: ["s2"], depends_on: ["a"]},
        "c" => %{mission: "third", skills: ["s3"], depends_on: ["b"]}
      }

      assert {:ok, [["a"], ["b"], ["c"]]} = AgentScheduler.plan_waves(dispatches)
    end

    test "mixed independent and dependent agents" do
      dispatches = %{
        "independent" => %{mission: "solo", skills: ["s1"]},
        "root" => %{mission: "root", skills: ["s2"]},
        "dependent" => %{mission: "needs root", skills: ["s3"], depends_on: ["root"]}
      }

      assert {:ok, [wave_0, wave_1]} = AgentScheduler.plan_waves(dispatches)
      assert "independent" in wave_0
      assert "root" in wave_0
      assert wave_1 == ["dependent"]
    end

    test "detects cycle between two agents" do
      dispatches = %{
        "a" => %{mission: "a", skills: ["s1"], depends_on: ["b"]},
        "b" => %{mission: "b", skills: ["s2"], depends_on: ["a"]}
      }

      assert {:error, :cycle_detected} = AgentScheduler.plan_waves(dispatches)
    end

    test "detects cycle in three-node ring" do
      dispatches = %{
        "a" => %{mission: "a", skills: ["s1"], depends_on: ["c"]},
        "b" => %{mission: "b", skills: ["s2"], depends_on: ["a"]},
        "c" => %{mission: "c", skills: ["s3"], depends_on: ["b"]}
      }

      assert {:error, :cycle_detected} = AgentScheduler.plan_waves(dispatches)
    end

    test "detects unknown dependency" do
      dispatches = %{
        "a" => %{mission: "a", skills: ["s1"], depends_on: ["nonexistent"]}
      }

      assert {:error, :unknown_dependency, "nonexistent"} =
               AgentScheduler.plan_waves(dispatches)
    end

    test "handles string-keyed depends_on" do
      dispatches = %{
        "a" => %{mission: "first", skills: ["s1"]},
        "b" => %{"depends_on" => ["a"], mission: "second", skills: ["s2"]}
      }

      assert {:ok, [["a"], ["b"]]} = AgentScheduler.plan_waves(dispatches)
    end

    test "handles nil depends_on gracefully" do
      dispatches = %{
        "a" => %{mission: "a", skills: ["s1"], depends_on: nil}
      }

      assert {:ok, [["a"]]} = AgentScheduler.plan_waves(dispatches)
    end
  end

  # ---------------------------------------------------------------
  # execute/3 — Wave execution with Task.Supervisor
  # ---------------------------------------------------------------

  describe "execute/3" do
    setup do
      {:ok, sup} = Task.Supervisor.start_link()
      %{supervisor: sup}
    end

    test "executes single agent and returns result", %{supervisor: sup} do
      dispatches = %{
        "a" => %{mission: "task", skills: ["s1"]}
      }

      execute_fn = fn _dispatch, _dep_results ->
        %{status: :completed, result: "done", tool_calls_used: 0}
      end

      assert {:ok, results} = AgentScheduler.execute(dispatches, sup, execute_fn)
      assert results["a"].status == :completed
      assert results["a"].result == "done"
    end

    test "passes dependency results to downstream agents", %{supervisor: sup} do
      dispatches = %{
        "a" => %{mission: "first", skills: ["s1"]},
        "b" => %{mission: "second", skills: ["s2"], depends_on: ["a"]}
      }

      execute_fn = fn dispatch, dep_results ->
        if dispatch.mission == "second" do
          # Should receive agent_a's result
          a_result = dep_results["a"]

          %{
            status: :completed,
            result: "got upstream: #{a_result.result}",
            tool_calls_used: 0
          }
        else
          %{status: :completed, result: "from_a", tool_calls_used: 1}
        end
      end

      assert {:ok, results} = AgentScheduler.execute(dispatches, sup, execute_fn)
      assert results["a"].result == "from_a"
      assert results["b"].result == "got upstream: from_a"
    end

    test "parallel agents in same wave execute concurrently", %{supervisor: sup} do
      dispatches = %{
        "a" => %{mission: "a", skills: ["s1"]},
        "b" => %{mission: "b", skills: ["s2"]}
      }

      test_pid = self()

      execute_fn = fn dispatch, _dep_results ->
        send(test_pid, {:started, dispatch.mission})
        Process.sleep(50)
        %{status: :completed, result: "done_#{dispatch.mission}", tool_calls_used: 0}
      end

      assert {:ok, results} = AgentScheduler.execute(dispatches, sup, execute_fn)
      assert results["a"].status == :completed
      assert results["b"].status == :completed

      # Both should have started (messages received)
      assert_received {:started, "a"}
      assert_received {:started, "b"}
    end

    test "failed agent causes transitive dependents to be skipped", %{supervisor: sup} do
      dispatches = %{
        "a" => %{mission: "will fail", skills: ["s1"]},
        "b" => %{mission: "depends on a", skills: ["s2"], depends_on: ["a"]},
        "c" => %{mission: "depends on b", skills: ["s3"], depends_on: ["b"]}
      }

      execute_fn = fn dispatch, _dep_results ->
        if dispatch.mission == "will fail" do
          %{status: :failed, result: "crashed", tool_calls_used: 0}
        else
          %{status: :completed, result: "ok", tool_calls_used: 0}
        end
      end

      assert {:ok, results} = AgentScheduler.execute(dispatches, sup, execute_fn)
      assert results["a"].status == :failed
      assert results["b"].status == :skipped
      assert results["c"].status == :skipped
    end

    test "returns error for cyclic dependencies", %{supervisor: sup} do
      dispatches = %{
        "a" => %{mission: "a", skills: ["s1"], depends_on: ["b"]},
        "b" => %{mission: "b", skills: ["s2"], depends_on: ["a"]}
      }

      execute_fn = fn _d, _r -> %{status: :completed, result: "ok", tool_calls_used: 0} end
      assert {:error, :cycle_detected} = AgentScheduler.execute(dispatches, sup, execute_fn)
    end

    test "agent crash is captured as failed status", %{supervisor: sup} do
      dispatches = %{
        "crasher" => %{mission: "crash", skills: ["s1"]}
      }

      execute_fn = fn _d, _r -> raise "boom" end

      assert {:ok, results} = AgentScheduler.execute(dispatches, sup, execute_fn)
      assert results["crasher"].status == :failed
      assert results["crasher"].result =~ "crashed"
    end
  end

  # ---------------------------------------------------------------
  # wait_for_agents/4
  # ---------------------------------------------------------------

  describe "wait_for_agents/4" do
    setup do
      {:ok, sup} = Task.Supervisor.start_link()
      %{supervisor: sup}
    end

    test "wait_all returns results for all specified agents", %{supervisor: sup} do
      task_a = Task.Supervisor.async_nolink(sup, fn -> %{status: :completed, result: "a"} end)
      task_b = Task.Supervisor.async_nolink(sup, fn -> %{status: :completed, result: "b"} end)

      agent_tasks = %{"a" => task_a, "b" => task_b}

      results = AgentScheduler.wait_for_agents(agent_tasks, ["a", "b"], :wait_all, 5_000)
      assert map_size(results) == 2
    end

    test "wait_any returns at least one result", %{supervisor: sup} do
      task_a =
        Task.Supervisor.async_nolink(sup, fn ->
          Process.sleep(10)
          %{status: :completed, result: "fast"}
        end)

      task_b =
        Task.Supervisor.async_nolink(sup, fn ->
          Process.sleep(5_000)
          %{status: :completed, result: "slow"}
        end)

      agent_tasks = %{"a" => task_a, "b" => task_b}
      results = AgentScheduler.wait_for_agents(agent_tasks, ["a", "b"], :wait_any, 2_000)

      # At minimum agent_a should have completed
      assert map_size(results) >= 1
    end

    test "returns empty map for unknown agent_ids", %{supervisor: sup} do
      task_a = Task.Supervisor.async_nolink(sup, fn -> %{status: :completed} end)
      agent_tasks = %{"a" => task_a}

      # Wait on yield to avoid dangling tasks
      Task.yield(task_a, 1_000)

      results = AgentScheduler.wait_for_agents(agent_tasks, ["unknown"], :wait_all, 100)
      assert results == %{}
    end
  end
end
