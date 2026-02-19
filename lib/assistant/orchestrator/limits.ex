# lib/assistant/orchestrator/limits.ex — Consolidated limit-checking facade.
#
# Wraps Assistant.Resilience.CircuitBreaker to provide a single entry point
# for all four levels of the limit hierarchy. Used by the SubAgent loop
# (levels 1-2), the Engine (levels 3-4), and any future code that needs
# to check resource budgets before executing skill calls.
#
# Related files:
#   - lib/assistant/resilience/circuit_breaker.ex (underlying implementation)
#   - lib/assistant/orchestrator/sub_agent.ex (uses check_skill/2, check_agent/2)
#   - lib/assistant/orchestrator/engine.ex (uses check_turn/2, check_conversation/2)

defmodule Assistant.Orchestrator.Limits do
  @moduledoc """
  Consolidated limit-checking facade for the four-level circuit breaker hierarchy.

  Provides thin wrappers around `Assistant.Resilience.CircuitBreaker` with
  consistent return types and domain-specific naming. Each function checks
  one level of the hierarchy and returns the updated state on success.

  ## Levels

  | Level | Scope            | Function               | Default Limit      |
  |-------|------------------|------------------------|---------------------|
  | 1     | Per-skill        | `check_skill/1`        | 3 failures / 60s   |
  | 2     | Per-agent        | `check_agent/2`        | 5 calls / agent    |
  | 3     | Per-turn         | `check_turn_agents/2`  | 8 agents / turn    |
  | 3     | Per-turn         | `check_turn_skills/2`  | 30 skill calls / turn |
  | 4     | Per-conversation | `check_conversation/2` | 50 calls / 5 min   |

  ## Return Conventions

  All check functions return:
    - `{:ok, updated_state}` when the action is within limits
    - `{:error, :circuit_open}` when a Level 1 fuse has blown
    - `{:error, :limit_exceeded, details}` when a Level 2-4 counter is full

  ## Combined Check

  `check_all/4` performs levels 1-4 in sequence for a single skill call,
  short-circuiting on the first failure.
  """

  alias Assistant.Resilience.CircuitBreaker

  # --- Level 1: Per-Skill ---

  @doc """
  Check whether a skill's circuit breaker is closed (healthy).

  Delegates to `:fuse` via `CircuitBreaker.check_skill/1`. Does not
  modify any state — the fuse is managed internally by the `:fuse` library.

  ## Parameters

    * `skill_name` - The skill to check (e.g., "email.send")

  ## Returns

    * `{:ok, :closed}` - Circuit is closed, skill can be called
    * `{:error, :circuit_open}` - Fuse has blown, skill is unavailable
  """
  @spec check_skill(term()) :: {:ok, :closed} | {:error, :circuit_open}
  defdelegate check_skill(skill_name), to: CircuitBreaker

  @doc """
  Record a skill execution failure to damage the fuse.
  """
  @spec record_skill_failure(term()) :: :ok
  defdelegate record_skill_failure(skill_name), to: CircuitBreaker

  @doc """
  Record a successful skill execution.
  """
  @spec record_skill_success(term()) :: :ok
  defdelegate record_skill_success(skill_name), to: CircuitBreaker

  # --- Level 2: Per-Agent ---

  @doc """
  Create a fresh per-agent state for tracking skill calls within one sub-agent.

  ## Options

    * `:max_skill_calls` - Override the default limit (default: 5)
  """
  @spec new_agent_state(keyword()) :: map()
  defdelegate new_agent_state(opts \\ []), to: CircuitBreaker

  @doc """
  Check and increment the per-agent skill call counter.

  ## Parameters

    * `agent_state` - Map from `new_agent_state/1`
    * `call_count` - Number of skill calls being made (default: 1)

  ## Returns

    * `{:ok, updated_state}` - Call is within budget
    * `{:error, :limit_exceeded, details}` - Agent has exhausted its budget
  """
  @spec check_agent(map(), pos_integer()) ::
          {:ok, map()} | {:error, :limit_exceeded, map()}
  defdelegate check_agent(agent_state, call_count \\ 1), to: CircuitBreaker

  # --- Level 3: Per-Turn ---

  @doc """
  Create a fresh per-turn state for tracking agents and skill calls.

  ## Options

    * `:max_agents` - Override the default agent limit (default: 8)
    * `:max_skill_calls` - Override the default skill call limit (default: 30)
  """
  @spec new_turn_state(keyword()) :: map()
  defdelegate new_turn_state(opts \\ []), to: CircuitBreaker

  @doc """
  Check whether additional agents can be dispatched in this turn.

  ## Parameters

    * `turn_state` - Map from `new_turn_state/1`
    * `agent_count` - Number of agents being dispatched (default: 1)

  ## Returns

    * `{:ok, updated_state}` - Dispatch is within budget
    * `{:error, :limit_exceeded, details}` - Turn agent limit reached
  """
  @spec check_turn_agents(map(), pos_integer()) ::
          {:ok, map()} | {:error, :limit_exceeded, map()}
  defdelegate check_turn_agents(turn_state, agent_count \\ 1), to: CircuitBreaker

  @doc """
  Check whether additional skill calls are allowed in this turn.

  ## Parameters

    * `turn_state` - Map from `new_turn_state/1`
    * `call_count` - Number of skill calls being made (default: 1)

  ## Returns

    * `{:ok, updated_state}` - Call is within budget
    * `{:error, :limit_exceeded, details}` - Turn skill call limit reached
  """
  @spec check_turn_skill_calls(map(), pos_integer()) ::
          {:ok, map()} | {:error, :limit_exceeded, map()}
  defdelegate check_turn_skill_calls(turn_state, call_count \\ 1), to: CircuitBreaker

  # --- Level 4: Per-Conversation ---

  @doc """
  Create a fresh per-conversation sliding-window rate limiter state.

  ## Options

    * `:max_calls` - Override the default limit (default: 50)
    * `:window_ms` - Override the default window (default: 300,000ms = 5 min)
  """
  @spec new_conversation_state(keyword()) :: map()
  defdelegate new_conversation_state(opts \\ []), to: CircuitBreaker

  @doc """
  Check whether a skill call is allowed within the conversation's sliding window.

  ## Parameters

    * `conversation_state` - Map from `new_conversation_state/1`
    * `call_count` - Number of skill calls being made (default: 1)

  ## Returns

    * `{:ok, updated_state}` - Call is within budget
    * `{:error, :limit_exceeded, details}` - Conversation rate limit reached
  """
  @spec check_conversation(map(), pos_integer()) ::
          {:ok, map()} | {:error, :limit_exceeded, map()}
  defdelegate check_conversation(conversation_state, call_count \\ 1), to: CircuitBreaker

  # --- Combined Multi-Level Check ---

  @doc """
  Perform a combined check across all four levels for a single skill call.

  Checks levels 1 (per-skill fuse), 2 (per-agent counter), 3 (per-turn
  skill budget), and 4 (per-conversation sliding window) in sequence.
  Short-circuits on the first failure.

  ## Parameters

    * `skill_name` - The skill being called
    * `agent_state` - Per-agent state from `new_agent_state/1`
    * `turn_state` - Per-turn state from `new_turn_state/1`
    * `conversation_state` - Per-conversation state from `new_conversation_state/1`

  ## Returns

    * `{:ok, %{agent: map(), turn: map(), conversation: map()}}` - All clear
    * `{:error, :circuit_open}` - Level 1 fuse is blown
    * `{:error, :limit_exceeded, details}` - Level 2, 3, or 4 limit hit
  """
  @spec check_all(term(), map(), map(), map()) ::
          {:ok, %{agent: map(), turn: map(), conversation: map()}}
          | {:error, :circuit_open}
          | {:error, :limit_exceeded, map()}
  defdelegate check_all(skill_name, agent_state, turn_state, conversation_state),
    to: CircuitBreaker
end
