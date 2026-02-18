# lib/assistant/resilience/circuit_breaker.ex — Four-level circuit breaker hierarchy.
#
# Provides protection at four scopes: per-skill, per-agent, per-turn, and
# per-conversation. Level 1 (per-skill) uses the :fuse library for automatic
# open/close behavior. Levels 2-4 use counter-based limits enforced by the
# RateLimiter module.
#
# Used by the Orchestrator Engine and SubAgent execution loop to enforce
# resource limits at each scope level.

defmodule Assistant.Resilience.CircuitBreaker do
  @moduledoc """
  Four-level circuit breaker hierarchy for the Skills-First AI Assistant.

  ## Levels

  | Level | Scope            | What It Limits                          | Default                          |
  |-------|------------------|-----------------------------------------|----------------------------------|
  | 1     | Per-skill        | Individual skill execution failures     | 3 failures in 60s, 30s cooldown  |
  | 2     | Per-agent        | Tool calls within one sub-agent         | 5 calls per agent invocation     |
  | 3     | Per-turn         | Agents + skill calls per user message   | 8 agents, 30 skill calls         |
  | 4     | Per-conversation | Skill calls in sliding time window      | 50 calls per 5 min window        |

  ## Return Values

  All check functions return:
  - `{:ok, updated_state}` when the action is allowed
  - `{:error, :circuit_open}` when a Level 1 fuse has blown
  - `{:error, :limit_exceeded, details}` when a Level 2-4 limit is reached
  """

  alias Assistant.Resilience.RateLimiter

  require Logger

  # --- Level 1: Per-Skill (via :fuse) ---

  @skill_max_melts 3
  @skill_melt_period_ms :timer.seconds(60)
  @skill_reset_ms :timer.seconds(30)

  @doc """
  Installs a fuse for the given skill name.

  Call this once when a skill is first registered or on application startup.
  If the fuse already exists, this is a no-op (`:fuse.install/2` returns `:reset`
  for existing fuses).

  ## Parameters
    - `skill_name` — atom or string identifying the skill (e.g., `"email.send"`)
  """
  @spec install_skill_fuse(term()) :: :ok
  def install_skill_fuse(skill_name) do
    fuse_name = skill_fuse_name(skill_name)

    opts =
      {{:standard, @skill_max_melts, @skill_melt_period_ms},
       {:reset, @skill_reset_ms}}

    case :fuse.install(fuse_name, opts) do
      :ok -> :ok
      :reset -> :ok
    end
  end

  @doc """
  Checks whether a skill's circuit is open or closed.

  Returns `{:ok, :closed}` if the skill can be called, or
  `{:error, :circuit_open}` if the fuse has blown.

  ## Parameters
    - `skill_name` — atom or string identifying the skill
  """
  @spec check_skill(term()) :: {:ok, :closed} | {:error, :circuit_open}
  def check_skill(skill_name) do
    fuse_name = skill_fuse_name(skill_name)

    case :fuse.ask(fuse_name, :sync) do
      :ok ->
        {:ok, :closed}

      :blown ->
        Logger.warning("Circuit breaker OPEN for skill",
          skill: skill_name,
          level: 1
        )

        {:error, :circuit_open}

      {:error, :not_found} ->
        # Auto-install on first access if not yet installed
        install_skill_fuse(skill_name)
        {:ok, :closed}
    end
  end

  @doc """
  Records a failure for a skill, incrementally damaging its fuse.

  After `#{@skill_max_melts}` failures within `#{@skill_melt_period_ms}ms`,
  the fuse blows open and remains open for `#{@skill_reset_ms}ms`.
  """
  @spec record_skill_failure(term()) :: :ok
  def record_skill_failure(skill_name) do
    fuse_name = skill_fuse_name(skill_name)
    :fuse.melt(fuse_name)

    Logger.info("Skill failure recorded",
      skill: skill_name,
      level: 1
    )

    :ok
  end

  @doc """
  Records a successful skill execution, keeping the fuse healthy.

  Note: `:fuse` does not have an explicit success callback. Successes are
  implicit — the melt counter decays over the configured time window. This
  function is provided for API consistency and future extensibility.
  """
  @spec record_skill_success(term()) :: :ok
  def record_skill_success(_skill_name), do: :ok

  @doc """
  Manually resets a skill's fuse to the closed state.

  Useful for administrative recovery or testing.
  """
  @spec reset_skill_fuse(term()) :: :ok
  def reset_skill_fuse(skill_name) do
    fuse_name = skill_fuse_name(skill_name)

    case :fuse.reset(fuse_name) do
      :ok -> :ok
      {:error, :not_found} -> :ok
    end
  end

  # --- Level 2: Per-Agent ---

  @agent_max_skill_calls 5

  @doc """
  Creates a new per-agent counter state.

  Returns a map to be threaded through the sub-agent execution loop.

  ## Options
    - `:max_skill_calls` — override the default limit of #{@agent_max_skill_calls}
  """
  @spec new_agent_state(keyword()) :: map()
  def new_agent_state(opts \\ []) do
    %{
      skill_calls: 0,
      max_skill_calls: Keyword.get(opts, :max_skill_calls, @agent_max_skill_calls)
    }
  end

  @doc """
  Checks and increments the per-agent skill call counter.

  Returns `{:ok, updated_state}` if the agent has budget remaining,
  or `{:error, :limit_exceeded, details}` if the limit has been reached.

  ## Parameters
    - `agent_state` — map from `new_agent_state/1`
    - `call_count` — number of skill calls being made (default: 1)
  """
  @spec check_agent(map(), pos_integer()) ::
          {:ok, map()} | {:error, :limit_exceeded, map()}
  def check_agent(agent_state, call_count \\ 1) do
    new_count = agent_state.skill_calls + call_count

    if new_count > agent_state.max_skill_calls do
      Logger.warning("Agent skill call limit reached",
        used: agent_state.skill_calls,
        requested: call_count,
        max: agent_state.max_skill_calls,
        level: 2
      )

      {:error, :limit_exceeded,
       %{
         level: 2,
         scope: :agent,
         used: agent_state.skill_calls,
         max: agent_state.max_skill_calls
       }}
    else
      {:ok, %{agent_state | skill_calls: new_count}}
    end
  end

  # --- Level 3: Per-Turn ---

  @turn_max_agents 8
  @turn_max_skill_calls 30

  @doc """
  Creates a new per-turn counter state.

  Returns a map to be threaded through the orchestrator's turn loop.

  ## Options
    - `:max_agents` — override the default limit of #{@turn_max_agents}
    - `:max_skill_calls` — override the default limit of #{@turn_max_skill_calls}
  """
  @spec new_turn_state(keyword()) :: map()
  def new_turn_state(opts \\ []) do
    %{
      agents_dispatched: 0,
      skill_calls: 0,
      max_agents: Keyword.get(opts, :max_agents, @turn_max_agents),
      max_skill_calls: Keyword.get(opts, :max_skill_calls, @turn_max_skill_calls)
    }
  end

  @doc """
  Checks whether additional agents can be dispatched in this turn.

  Returns `{:ok, updated_state}` if the agent dispatch is allowed,
  or `{:error, :limit_exceeded, details}` if the agent limit is reached.

  ## Parameters
    - `turn_state` — map from `new_turn_state/1`
    - `agent_count` — number of agents being dispatched (default: 1)
  """
  @spec check_turn_agents(map(), pos_integer()) ::
          {:ok, map()} | {:error, :limit_exceeded, map()}
  def check_turn_agents(turn_state, agent_count \\ 1) do
    new_count = turn_state.agents_dispatched + agent_count

    if new_count > turn_state.max_agents do
      Logger.warning("Turn agent dispatch limit reached",
        dispatched: turn_state.agents_dispatched,
        requested: agent_count,
        max: turn_state.max_agents,
        level: 3
      )

      {:error, :limit_exceeded,
       %{
         level: 3,
         scope: :turn_agents,
         used: turn_state.agents_dispatched,
         max: turn_state.max_agents
       }}
    else
      {:ok, %{turn_state | agents_dispatched: new_count}}
    end
  end

  @doc """
  Checks whether additional skill calls are allowed in this turn.

  Returns `{:ok, updated_state}` if the skill call budget permits,
  or `{:error, :limit_exceeded, details}` if the skill call limit is reached.

  ## Parameters
    - `turn_state` — map from `new_turn_state/1`
    - `call_count` — number of skill calls being made (default: 1)
  """
  @spec check_turn_skill_calls(map(), pos_integer()) ::
          {:ok, map()} | {:error, :limit_exceeded, map()}
  def check_turn_skill_calls(turn_state, call_count \\ 1) do
    new_count = turn_state.skill_calls + call_count

    if new_count > turn_state.max_skill_calls do
      Logger.warning("Turn skill call limit reached",
        used: turn_state.skill_calls,
        requested: call_count,
        max: turn_state.max_skill_calls,
        level: 3
      )

      {:error, :limit_exceeded,
       %{
         level: 3,
         scope: :turn_skill_calls,
         used: turn_state.skill_calls,
         max: turn_state.max_skill_calls
       }}
    else
      {:ok, %{turn_state | skill_calls: new_count}}
    end
  end

  # --- Level 4: Per-Conversation (Sliding Window) ---

  @conversation_max_calls 50
  @conversation_window_ms :timer.minutes(5)

  @doc """
  Creates a new per-conversation rate limiter state.

  Uses a sliding window to track skill calls over the configured time window.

  ## Options
    - `:max_calls` — override the default limit of #{@conversation_max_calls}
    - `:window_ms` — override the default window of #{@conversation_window_ms}ms
  """
  @spec new_conversation_state(keyword()) :: map()
  def new_conversation_state(opts \\ []) do
    RateLimiter.new(
      max_calls: Keyword.get(opts, :max_calls, @conversation_max_calls),
      window_ms: Keyword.get(opts, :window_ms, @conversation_window_ms)
    )
  end

  @doc """
  Checks whether a skill call is allowed within the conversation's sliding window.

  Returns `{:ok, updated_state}` if the call is within budget,
  or `{:error, :limit_exceeded, details}` if the sliding window limit is reached.

  ## Parameters
    - `conversation_state` — map from `new_conversation_state/1`
    - `call_count` — number of skill calls being made (default: 1)
  """
  @spec check_conversation(map(), pos_integer()) ::
          {:ok, map()} | {:error, :limit_exceeded, map()}
  def check_conversation(conversation_state, call_count \\ 1) do
    case RateLimiter.check(conversation_state, call_count) do
      {:ok, new_state} ->
        {:ok, new_state}

      {:error, details} ->
        Logger.warning("Conversation rate limit reached",
          used: details.current_count,
          max: details.max_calls,
          window_ms: details.window_ms,
          level: 4
        )

        {:error, :limit_exceeded,
         Map.merge(details, %{level: 4, scope: :conversation})}
    end
  end

  # --- Multi-Level Check ---

  @doc """
  Performs a combined check across all applicable levels for a skill call.

  Checks levels 1, 2, 3 (skill budget), and 4 in sequence. Short-circuits
  on the first failure.

  Returns `{:ok, %{agent: updated_agent, turn: updated_turn, conversation: updated_conv}}`
  on success, or the first error encountered.

  ## Parameters
    - `skill_name` — the skill being called
    - `agent_state` — per-agent state from `new_agent_state/1`
    - `turn_state` — per-turn state from `new_turn_state/1`
    - `conversation_state` — per-conversation state from `new_conversation_state/1`
  """
  @spec check_all(term(), map(), map(), map()) ::
          {:ok, %{agent: map(), turn: map(), conversation: map()}}
          | {:error, :circuit_open}
          | {:error, :limit_exceeded, map()}
  def check_all(skill_name, agent_state, turn_state, conversation_state) do
    with {:ok, :closed} <- check_skill(skill_name),
         {:ok, new_agent} <- check_agent(agent_state),
         {:ok, new_turn} <- check_turn_skill_calls(turn_state),
         {:ok, new_conv} <- check_conversation(conversation_state) do
      {:ok, %{agent: new_agent, turn: new_turn, conversation: new_conv}}
    end
  end

  # --- Private Helpers ---

  defp skill_fuse_name(skill_name) do
    {:skill_circuit, skill_name}
  end
end
