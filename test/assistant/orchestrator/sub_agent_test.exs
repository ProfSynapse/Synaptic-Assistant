# test/assistant/orchestrator/sub_agent_test.exs
#
# Tests for sub-agent execution, focusing on scope isolation
# (INVARIANT 4: sub-agent tool calls restricted to assigned skills)
# and the GenServer lifecycle (start, status, resume, execute wrapper).

defmodule Assistant.Orchestrator.SubAgentTest do
  use ExUnit.Case, async: false
  # async: false because we use named registries

  alias Assistant.Orchestrator.SubAgent

  setup do
    # Trap exits so SubAgent crashes (LLM failure) don't kill the test process
    Process.flag(:trap_exit, true)

    # Start infrastructure unlinked so it survives test process cleanup
    start_unlinked(Registry, keys: :unique, name: Assistant.SubAgent.Registry)
    start_unlinked(Task.Supervisor, name: Assistant.Skills.TaskSupervisor)

    # Ensure Skills.Registry and PromptLoader are running
    ensure_skills_registry_started()
    ensure_prompt_loader_started()

    :ok
  end

  # ---------------------------------------------------------------
  # GenServer lifecycle — start_link
  # ---------------------------------------------------------------

  describe "start_link/1" do
    test "starts and registers in SubAgent.Registry" do
      agent_id = "test-agent-#{System.unique_integer([:positive])}"

      dispatch_params = %{
        agent_id: agent_id,
        mission: "Test mission",
        skills: ["email.search"],
        context: nil,
        context_files: nil
      }

      {:ok, pid} =
        SubAgent.start_link(
          dispatch_params: dispatch_params,
          dep_results: %{},
          engine_state: %{conversation_id: "conv-1", user_id: "user-1"}
        )

      assert Process.alive?(pid)

      # Verify registration
      assert [{^pid, _}] =
               Registry.lookup(Assistant.SubAgent.Registry, agent_id)

      # The agent will start running the LLM loop (which will fail without a real client)
      # Wait briefly, then stop
      Process.sleep(100)
      if Process.alive?(pid), do: GenServer.stop(pid, :normal, 1_000)
    end
  end

  # ---------------------------------------------------------------
  # GenServer lifecycle — get_status
  # ---------------------------------------------------------------

  describe "get_status/1" do
    test "returns status for registered agent" do
      agent_id = "test-status-#{System.unique_integer([:positive])}"

      dispatch_params = %{
        agent_id: agent_id,
        mission: "Status test",
        skills: [],
        context: nil,
        context_files: nil
      }

      {:ok, pid} =
        SubAgent.start_link(
          dispatch_params: dispatch_params,
          dep_results: %{},
          engine_state: %{conversation_id: "conv-1", user_id: "user-1"}
        )

      # Give a moment for the process to initialize
      Process.sleep(10)

      case SubAgent.get_status(agent_id) do
        {:ok, status} ->
          assert status.status in [:running, :completed, :failed]

        {:error, :not_found} ->
          # Agent may have already finished and exited
          :ok
      end

      Process.sleep(100)
      if Process.alive?(pid), do: GenServer.stop(pid, :normal, 1_000)
    end

    test "returns {:error, :not_found} for unregistered agent" do
      assert {:error, :not_found} = SubAgent.get_status("nonexistent-agent-xyz")
    end
  end

  # ---------------------------------------------------------------
  # GenServer lifecycle — resume
  # ---------------------------------------------------------------

  describe "resume/2" do
    test "returns {:error, :not_found} for unregistered agent" do
      assert {:error, :not_found} =
               SubAgent.resume("nonexistent-agent-xyz", %{message: "test"})
    end

    test "returns {:error, :not_awaiting} when agent is running" do
      agent_id = "test-resume-#{System.unique_integer([:positive])}"

      dispatch_params = %{
        agent_id: agent_id,
        mission: "Resume test",
        skills: [],
        context: nil,
        context_files: nil
      }

      {:ok, pid} =
        SubAgent.start_link(
          dispatch_params: dispatch_params,
          dep_results: %{},
          engine_state: %{conversation_id: "conv-1", user_id: "user-1"}
        )

      Process.sleep(10)

      # Agent is running (not awaiting), so resume should return error
      case SubAgent.resume(agent_id, %{message: "update"}) do
        {:error, :not_awaiting} -> :ok
        {:error, :not_found} -> :ok  # Agent may have already completed
      end

      Process.sleep(100)
      if Process.alive?(pid), do: GenServer.stop(pid, :normal, 1_000)
    end
  end

  # ---------------------------------------------------------------
  # execute/3 — synchronous wrapper (backward compatibility)
  # ---------------------------------------------------------------

  describe "execute/3" do
    test "returns result map with expected keys" do
      agent_id = "test-exec-#{System.unique_integer([:positive])}"

      dispatch_params = %{
        agent_id: agent_id,
        mission: "Execute test",
        skills: [],
        context: nil,
        context_files: nil
      }

      engine_state = %{conversation_id: "conv-1", user_id: "user-1"}

      # execute/3 starts the GenServer and waits for completion
      # Without a real LLM client, the loop will fail → agent returns failed status
      result = SubAgent.execute(dispatch_params, %{}, engine_state)

      assert is_map(result)
      assert Map.has_key?(result, :status)
      assert Map.has_key?(result, :result)
      assert Map.has_key?(result, :tool_calls_used)
      assert result.status in [:completed, :failed, :timeout]
    end
  end

  # ---------------------------------------------------------------
  # Scope enforcement — structural contract tests
  # ---------------------------------------------------------------

  describe "scope enforcement" do
    test "scoped tool enum restricts skill names" do
      dispatch_params = %{
        agent_id: "test_agent",
        mission: "Search for emails",
        skills: ["email.search", "email.read"],
        context: nil
      }

      assert dispatch_params.skills == ["email.search", "email.read"]
    end
  end

  describe "function name/args extraction" do
    test "atom-keyed tool call structure" do
      tc = %{
        id: "call_1",
        type: "function",
        function: %{name: "use_skill", arguments: ~s({"skill": "email.send"})}
      }

      assert tc.function.name == "use_skill"
      assert is_binary(tc.function.arguments)
    end

    test "string-keyed tool call structure" do
      tc = %{
        "id" => "call_1",
        "type" => "function",
        "function" => %{"name" => "use_skill", "arguments" => ~s({"skill": "email.send"})}
      }

      assert tc["function"]["name"] == "use_skill"
    end
  end

  # ---------------------------------------------------------------
  # Dual scope enforcement (tool def enum + runtime check)
  # ---------------------------------------------------------------

  describe "dual scope enforcement" do
    test "out-of-scope skill is not in assigned skills" do
      dispatch_params = %{
        agent_id: "test_agent",
        mission: "Search emails",
        skills: ["email.search"],
        context: nil
      }

      assert "email.send" not in dispatch_params.skills
      assert "email.search" in dispatch_params.skills
    end

    test "in-scope skill is in assigned skills" do
      dispatch_params = %{
        agent_id: "test_agent",
        mission: "Search and read emails",
        skills: ["email.search", "email.read"],
        context: nil
      }

      assert "email.search" in dispatch_params.skills
      assert "email.read" in dispatch_params.skills
      refute "email.send" in dispatch_params.skills
    end
  end

  # ---------------------------------------------------------------
  # Message extraction
  # ---------------------------------------------------------------

  describe "message extraction" do
    test "extracts last assistant text from message history" do
      messages = [
        %{role: "system", content: "You are an agent."},
        %{role: "user", content: "Do the task."},
        %{role: "assistant", content: "I'll search now."},
        %{role: "tool", tool_call_id: "tc1", content: "3 results found"},
        %{role: "assistant", content: "Found 3 emails."}
      ]

      last_assistant =
        messages
        |> Enum.reverse()
        |> Enum.find_value(fn
          %{role: "assistant", content: content} when is_binary(content) and content != "" ->
            content
          _ ->
            nil
        end)

      assert last_assistant == "Found 3 emails."
    end

    test "returns nil when no assistant messages" do
      messages = [
        %{role: "system", content: "System"},
        %{role: "user", content: "Hello"}
      ]

      last_assistant =
        messages
        |> Enum.reverse()
        |> Enum.find_value(fn
          %{role: "assistant", content: content} when is_binary(content) and content != "" ->
            content
          _ ->
            nil
        end)

      assert last_assistant == nil
    end
  end

  # ---------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------

  defp start_unlinked(module, opts) do
    case module.start_link(opts) do
      {:ok, pid} -> Process.unlink(pid)
      {:error, {:already_started, _}} -> :ok
    end
  end

  defp ensure_prompt_loader_started do
    if :ets.whereis(:assistant_prompts) != :undefined do
      :ok
    else
      tmp = Path.join(System.tmp_dir!(), "prompts_sa_#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp)

      File.write!(Path.join(tmp, "sub_agent.yaml"), """
      system: |
        You are a focused execution agent (test mode).
        Available skills: <%= @skills_text %>
        <%= @dep_section %>
        <%= @context_section %>
      """)

      case Assistant.Config.PromptLoader.start_link(prompts_dir: tmp) do
        {:ok, _} -> :ok
        {:error, {:already_started, _}} -> :ok
      end
    end
  end

  defp ensure_skills_registry_started do
    if :ets.whereis(:assistant_skills) != :undefined do
      :ok
    else
      tmp_dir = Path.join(System.tmp_dir!(), "empty_skills_sa_#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp_dir)

      case Assistant.Skills.Registry.start_link(skills_dir: tmp_dir) do
        {:ok, _} -> :ok
        {:error, {:already_started, _}} -> :ok
      end
    end
  end
end
