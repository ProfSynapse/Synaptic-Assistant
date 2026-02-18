# test/assistant/memory/agent_test.exs
#
# Tests for the Memory Agent GenServer lifecycle and dispatch interface.
# Tests the public API surface: start_link, dispatch, get_status, resume.
#
# The LLM call will fail (no real client or mock configured) which exercises
# the error recovery path and proves the agent returns to :idle after failure.

defmodule Assistant.Memory.AgentTest do
  use ExUnit.Case, async: false
  # async: false because we use named registries and ETS tables

  alias Assistant.Memory.Agent, as: MemoryAgent

  setup do
    # Start infrastructure processes, idempotently and unlinked.
    # Order matters: PubSub -> TaskSupervisor -> SubAgent.Registry -> Skills.Registry -> PromptLoader
    # Using Process.unlink so infrastructure survives test process cleanup.

    Application.ensure_all_started(:phoenix_pubsub)

    start_unlinked(Phoenix.PubSub.Supervisor, name: Assistant.PubSub)
    start_unlinked(Task.Supervisor, name: Assistant.Skills.TaskSupervisor)

    # SubAgent.Registry (Elixir.Registry for via_tuple lookups)
    start_unlinked(Elixir.Registry, keys: :unique, name: Assistant.SubAgent.Registry)

    # Skills.Registry (ETS-backed GenServer for skill lookups)
    if :ets.whereis(:assistant_skills) == :undefined do
      tmp = Path.join(System.tmp_dir!(), "empty_skills_#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp)
      start_unlinked(Assistant.Skills.Registry, skills_dir: tmp)
    end

    # PromptLoader (ETS-backed GenServer for prompt templates)
    if :ets.whereis(:assistant_prompts) == :undefined do
      tmp = Path.join(System.tmp_dir!(), "prompts_#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp)

      File.write!(Path.join(tmp, "memory_agent.yaml"), """
      system: |
        You are the Memory Agent (test mode).
        Date: <%= @current_date %>
        <%= @skills_text %>
      """)

      start_unlinked(Assistant.Config.PromptLoader, dir: tmp)
    end

    user_id = "mem-agent-test-#{System.unique_integer([:positive])}"

    on_exit(fn ->
      # Clean up any leftover MemoryAgent for this user_id
      case Elixir.Registry.lookup(Assistant.SubAgent.Registry, {:memory_agent, user_id}) do
        [{pid, _}] -> if Process.alive?(pid), do: GenServer.stop(pid, :normal, 500)
        [] -> :ok
      end
    end)

    %{user_id: user_id}
  end

  # ---------------------------------------------------------------
  # start_link/1
  # ---------------------------------------------------------------

  describe "start_link/1" do
    test "starts and registers in SubAgent.Registry", %{user_id: user_id} do
      {:ok, pid} = MemoryAgent.start_link(user_id: user_id)
      assert Process.alive?(pid)

      assert [{^pid, _}] =
               Elixir.Registry.lookup(Assistant.SubAgent.Registry, {:memory_agent, user_id})

      GenServer.stop(pid, :normal, 1_000)
    end

    test "get_status returns idle after start", %{user_id: user_id} do
      {:ok, pid} = MemoryAgent.start_link(user_id: user_id)

      assert {:ok, status} = MemoryAgent.get_status(user_id)
      assert status.status == :idle
      assert status.missions_completed == 0
      assert status.last_result == nil

      GenServer.stop(pid, :normal, 1_000)
    end

    test "duplicate user_id fails with already_started", %{user_id: user_id} do
      {:ok, pid} = MemoryAgent.start_link(user_id: user_id)
      assert {:error, {:already_started, ^pid}} = MemoryAgent.start_link(user_id: user_id)
      GenServer.stop(pid, :normal, 1_000)
    end
  end

  # ---------------------------------------------------------------
  # dispatch/2
  # ---------------------------------------------------------------

  describe "dispatch/2" do
    test "returns :ok when idle (transitions to running)", %{user_id: user_id} do
      {:ok, pid} = MemoryAgent.start_link(user_id: user_id)

      result = MemoryAgent.dispatch(user_id, %{mission: "Test mission"})
      assert result == :ok

      # Wait for the agent to settle (LLM fails, agent returns to idle)
      wait_for_idle(user_id, 2_000)
      GenServer.stop(pid, :normal, 1_000)
    end

    test "returns {:error, :not_found} for unregistered user" do
      assert {:error, :not_found} = MemoryAgent.dispatch("nonexistent-user", %{mission: "test"})
    end
  end

  # ---------------------------------------------------------------
  # handle_cast — mission dispatch from ContextMonitor/TurnClassifier
  # ---------------------------------------------------------------

  describe "handle_cast {:mission, action, params}" do
    test "save_memory cast accepted from idle state", %{user_id: user_id} do
      {:ok, pid} = MemoryAgent.start_link(user_id: user_id)

      GenServer.cast(pid, {:mission, :save_memory, %{
        conversation_id: "conv-1",
        user_id: user_id,
        user_message: "Hello",
        assistant_response: "Hi"
      }})

      # Agent eventually returns to idle (LLM fails without real client)
      wait_for_idle(user_id, 2_000)

      {:ok, status} = MemoryAgent.get_status(user_id)
      assert status.status == :idle

      GenServer.stop(pid, :normal, 1_000)
    end
  end

  # ---------------------------------------------------------------
  # resume/2
  # ---------------------------------------------------------------

  describe "resume/2" do
    test "returns {:error, :not_awaiting} when idle", %{user_id: user_id} do
      {:ok, pid} = MemoryAgent.start_link(user_id: user_id)

      assert {:error, :not_awaiting} =
               MemoryAgent.resume(user_id, %{message: "Help response"})

      GenServer.stop(pid, :normal, 1_000)
    end

    test "returns {:error, :not_found} for unregistered user" do
      assert {:error, :not_found} =
               MemoryAgent.resume("nonexistent-user", %{message: "test"})
    end
  end

  # ---------------------------------------------------------------
  # Mission completion — returns to :idle
  # ---------------------------------------------------------------

  describe "mission completion" do
    test "agent returns to idle after LLM error (no real client)", %{user_id: user_id} do
      {:ok, pid} = MemoryAgent.start_link(user_id: user_id)

      GenServer.cast(pid, {:mission, :compact_conversation, %{
        conversation_id: "conv-1",
        user_id: user_id,
        message_range: {1, 50}
      }})

      wait_for_idle(user_id, 2_000)

      {:ok, status} = MemoryAgent.get_status(user_id)
      assert status.status == :idle

      GenServer.stop(pid, :normal, 1_000)
    end

    test "missions_completed increments after dispatch cycle", %{user_id: user_id} do
      {:ok, pid} = MemoryAgent.start_link(user_id: user_id)

      :ok = MemoryAgent.dispatch(user_id, %{mission: "Test extraction"})
      wait_for_idle(user_id, 2_000)

      {:ok, status} = MemoryAgent.get_status(user_id)
      assert status.missions_completed >= 1

      GenServer.stop(pid, :normal, 1_000)
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

  defp wait_for_idle(user_id, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_idle(user_id, deadline)
  end

  defp do_wait_idle(user_id, deadline) do
    if System.monotonic_time(:millisecond) > deadline do
      flunk("Timed out waiting for MemoryAgent to return to :idle")
    end

    case MemoryAgent.get_status(user_id) do
      {:ok, %{status: :idle}} ->
        :ok

      {:ok, _} ->
        Process.sleep(50)
        do_wait_idle(user_id, deadline)

      {:error, :not_found} ->
        :ok
    end
  end
end
