# test/assistant/resilience/circuit_breaker_test.exs
#
# Tests for the four-level circuit breaker hierarchy.
# Level 1 (per-skill) uses :fuse and needs the :fuse app started.
# Levels 2-4 are counter/rate-limiter based — pure state.

defmodule Assistant.Resilience.CircuitBreakerTest do
  use ExUnit.Case, async: false
  # async: false because :fuse uses global state

  alias Assistant.Resilience.CircuitBreaker

  setup do
    # Ensure :fuse application is running for Level 1 tests
    Application.ensure_all_started(:fuse)
    :ok
  end

  # ---------------------------------------------------------------
  # Level 1: Per-Skill (via :fuse)
  # ---------------------------------------------------------------

  describe "Level 1: per-skill circuit breaker" do
    test "install_skill_fuse/1 installs without error" do
      assert :ok = CircuitBreaker.install_skill_fuse("test.skill_install")
    end

    test "check_skill/1 returns closed for healthy skill" do
      CircuitBreaker.install_skill_fuse("test.healthy")
      assert {:ok, :closed} = CircuitBreaker.check_skill("test.healthy")
    end

    test "check_skill/1 auto-installs fuse on first access" do
      # Use a unique name that was never installed
      unique = "test.auto_install_#{System.unique_integer([:positive])}"
      assert {:ok, :closed} = CircuitBreaker.check_skill(unique)
    end

    test "circuit opens after 3 failures within window" do
      skill = "test.breaker_#{System.unique_integer([:positive])}"
      CircuitBreaker.install_skill_fuse(skill)

      # Record 3 failures (default max_melts)
      CircuitBreaker.record_skill_failure(skill)
      CircuitBreaker.record_skill_failure(skill)
      CircuitBreaker.record_skill_failure(skill)

      # Extra melt to push past the threshold
      CircuitBreaker.record_skill_failure(skill)

      assert {:error, :circuit_open} = CircuitBreaker.check_skill(skill)
    end

    test "reset_skill_fuse/1 closes an open circuit" do
      skill = "test.reset_#{System.unique_integer([:positive])}"
      CircuitBreaker.install_skill_fuse(skill)

      # Blow the fuse
      for _ <- 1..5, do: CircuitBreaker.record_skill_failure(skill)

      assert {:error, :circuit_open} = CircuitBreaker.check_skill(skill)

      # Reset it
      CircuitBreaker.reset_skill_fuse(skill)
      assert {:ok, :closed} = CircuitBreaker.check_skill(skill)
    end

    test "record_skill_success/1 returns :ok (no-op for :fuse)" do
      assert :ok = CircuitBreaker.record_skill_success("any_skill")
    end
  end

  # ---------------------------------------------------------------
  # Level 2: Per-Agent
  # ---------------------------------------------------------------

  describe "Level 2: per-agent limits" do
    test "new_agent_state/0 creates state with default limit" do
      state = CircuitBreaker.new_agent_state()
      assert state.skill_calls == 0
      assert state.max_skill_calls == 5
    end

    test "new_agent_state/1 accepts custom limit" do
      state = CircuitBreaker.new_agent_state(max_skill_calls: 10)
      assert state.max_skill_calls == 10
    end

    test "check_agent/1 allows calls within budget" do
      state = CircuitBreaker.new_agent_state(max_skill_calls: 3)

      assert {:ok, state} = CircuitBreaker.check_agent(state)
      assert state.skill_calls == 1
      assert {:ok, state} = CircuitBreaker.check_agent(state)
      assert state.skill_calls == 2
      assert {:ok, state} = CircuitBreaker.check_agent(state)
      assert state.skill_calls == 3
    end

    test "check_agent/1 rejects calls exceeding budget" do
      state = CircuitBreaker.new_agent_state(max_skill_calls: 2)

      {:ok, state} = CircuitBreaker.check_agent(state)
      {:ok, state} = CircuitBreaker.check_agent(state)

      assert {:error, :limit_exceeded, details} = CircuitBreaker.check_agent(state)
      assert details.level == 2
      assert details.scope == :agent
      assert details.used == 2
      assert details.max == 2
    end

    test "check_agent/2 supports multi-count check" do
      state = CircuitBreaker.new_agent_state(max_skill_calls: 5)

      assert {:ok, state} = CircuitBreaker.check_agent(state, 3)
      assert state.skill_calls == 3
      assert {:error, :limit_exceeded, _} = CircuitBreaker.check_agent(state, 4)
    end
  end

  # ---------------------------------------------------------------
  # Level 3: Per-Turn
  # ---------------------------------------------------------------

  describe "Level 3: per-turn limits" do
    test "new_turn_state/0 creates state with default limits" do
      state = CircuitBreaker.new_turn_state()
      assert state.agents_dispatched == 0
      assert state.skill_calls == 0
      assert state.max_agents == 8
      assert state.max_skill_calls == 30
    end

    test "new_turn_state/1 accepts custom limits" do
      state = CircuitBreaker.new_turn_state(max_agents: 4, max_skill_calls: 15)
      assert state.max_agents == 4
      assert state.max_skill_calls == 15
    end

    test "check_turn_agents/1 allows within budget" do
      state = CircuitBreaker.new_turn_state(max_agents: 2)

      assert {:ok, state} = CircuitBreaker.check_turn_agents(state)
      assert state.agents_dispatched == 1
      assert {:ok, _} = CircuitBreaker.check_turn_agents(state)
    end

    test "check_turn_agents/1 rejects exceeding budget" do
      state = CircuitBreaker.new_turn_state(max_agents: 1)

      {:ok, state} = CircuitBreaker.check_turn_agents(state)
      assert {:error, :limit_exceeded, details} = CircuitBreaker.check_turn_agents(state)
      assert details.level == 3
      assert details.scope == :turn_agents
    end

    test "check_turn_skill_calls/1 allows within budget" do
      state = CircuitBreaker.new_turn_state(max_skill_calls: 3)

      assert {:ok, state} = CircuitBreaker.check_turn_skill_calls(state)
      assert {:ok, state} = CircuitBreaker.check_turn_skill_calls(state)
      assert {:ok, _} = CircuitBreaker.check_turn_skill_calls(state)
    end

    test "check_turn_skill_calls/1 rejects exceeding budget" do
      state = CircuitBreaker.new_turn_state(max_skill_calls: 2)

      {:ok, state} = CircuitBreaker.check_turn_skill_calls(state)
      {:ok, state} = CircuitBreaker.check_turn_skill_calls(state)

      assert {:error, :limit_exceeded, details} = CircuitBreaker.check_turn_skill_calls(state)
      assert details.level == 3
      assert details.scope == :turn_skill_calls
    end

    test "check_turn_agents/2 supports multi-count dispatch" do
      state = CircuitBreaker.new_turn_state(max_agents: 5)
      assert {:ok, state} = CircuitBreaker.check_turn_agents(state, 3)
      assert state.agents_dispatched == 3
    end
  end

  # ---------------------------------------------------------------
  # Level 4: Per-Conversation (Sliding Window)
  # ---------------------------------------------------------------

  describe "Level 4: per-conversation limits" do
    test "new_conversation_state/0 creates state with defaults" do
      state = CircuitBreaker.new_conversation_state()
      assert state.max_calls == 50
      assert state.window_ms == 300_000
      assert state.timestamps == []
    end

    test "new_conversation_state/1 accepts custom limits" do
      state = CircuitBreaker.new_conversation_state(max_calls: 10, window_ms: 1000)
      assert state.max_calls == 10
      assert state.window_ms == 1000
    end

    test "check_conversation/1 allows calls within budget" do
      state = CircuitBreaker.new_conversation_state(max_calls: 3, window_ms: 60_000)

      assert {:ok, state} = CircuitBreaker.check_conversation(state)
      assert {:ok, state} = CircuitBreaker.check_conversation(state)
      assert {:ok, _} = CircuitBreaker.check_conversation(state)
    end

    test "check_conversation/1 rejects calls exceeding limit" do
      state = CircuitBreaker.new_conversation_state(max_calls: 2, window_ms: 60_000)

      {:ok, state} = CircuitBreaker.check_conversation(state)
      {:ok, state} = CircuitBreaker.check_conversation(state)

      assert {:error, :limit_exceeded, details} = CircuitBreaker.check_conversation(state)
      assert details.level == 4
      assert details.scope == :conversation
    end

    test "sliding window allows calls after expiry" do
      state = CircuitBreaker.new_conversation_state(max_calls: 2, window_ms: 50)

      {:ok, state} = CircuitBreaker.check_conversation(state)
      {:ok, state} = CircuitBreaker.check_conversation(state)
      assert {:error, :limit_exceeded, _} = CircuitBreaker.check_conversation(state)

      Process.sleep(60)

      assert {:ok, _} = CircuitBreaker.check_conversation(state)
    end
  end

  # ---------------------------------------------------------------
  # check_all/4 — Combined multi-level check
  # ---------------------------------------------------------------

  describe "check_all/4" do
    setup do
      Application.ensure_all_started(:fuse)

      skill = "test.check_all_#{System.unique_integer([:positive])}"
      CircuitBreaker.install_skill_fuse(skill)

      agent = CircuitBreaker.new_agent_state(max_skill_calls: 5)
      turn = CircuitBreaker.new_turn_state(max_skill_calls: 10)
      conv = CircuitBreaker.new_conversation_state(max_calls: 20, window_ms: 60_000)

      %{skill: skill, agent: agent, turn: turn, conversation: conv}
    end

    test "returns ok with updated states when all levels pass", ctx do
      assert {:ok, %{agent: new_agent, turn: new_turn, conversation: new_conv}} =
               CircuitBreaker.check_all(ctx.skill, ctx.agent, ctx.turn, ctx.conversation)

      assert new_agent.skill_calls == 1
      assert new_turn.skill_calls == 1
      assert length(new_conv.timestamps) == 1
    end

    test "short-circuits on Level 1 (circuit open)", ctx do
      # Blow the fuse
      for _ <- 1..5, do: CircuitBreaker.record_skill_failure(ctx.skill)

      assert {:error, :circuit_open} =
               CircuitBreaker.check_all(ctx.skill, ctx.agent, ctx.turn, ctx.conversation)
    end

    test "short-circuits on Level 2 (agent limit)", ctx do
      exhausted_agent = CircuitBreaker.new_agent_state(max_skill_calls: 0)

      assert {:error, :limit_exceeded, %{level: 2}} =
               CircuitBreaker.check_all(ctx.skill, exhausted_agent, ctx.turn, ctx.conversation)
    end

    test "short-circuits on Level 3 (turn limit)", ctx do
      exhausted_turn = CircuitBreaker.new_turn_state(max_skill_calls: 0)

      assert {:error, :limit_exceeded, %{level: 3}} =
               CircuitBreaker.check_all(ctx.skill, ctx.agent, exhausted_turn, ctx.conversation)
    end

    test "short-circuits on Level 4 (conversation limit)", ctx do
      exhausted_conv = CircuitBreaker.new_conversation_state(max_calls: 0, window_ms: 60_000)

      assert {:error, :limit_exceeded, %{level: 4}} =
               CircuitBreaker.check_all(ctx.skill, ctx.agent, ctx.turn, exhausted_conv)
    end
  end
end
