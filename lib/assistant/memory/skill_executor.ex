# lib/assistant/memory/skill_executor.ex — Search-first enforcement wrapper for memory skills.
#
# Wraps the standard Skills.Executor to enforce the search-first rule:
# write skills (save_memory, extract_entities, close_relation, compact_conversation)
# require a preceding read skill (search_memories, query_entity_graph) in the same
# dispatch session. This prevents duplicate entries and conflicting knowledge.
#
# Maintains per-session state tracking whether a read has been performed.
# State resets at the start of each new dispatch mission.
#
# Related files:
#   - lib/assistant/skills/executor.ex (underlying executor)
#   - lib/assistant/memory/agent.ex (consumer — memory agent GenServer)
#   - config/prompts/nudges.yaml (memory_write_without_search hint)

defmodule Assistant.Memory.SkillExecutor do
  @moduledoc """
  Search-first enforcement wrapper for memory skill execution.

  Maintains a per-session `has_searched` flag that gates write operations.
  Read skills set the flag; write skills check it. If a write is attempted
  without a preceding read, the executor returns `{:error, :memory_write_without_search}`
  and the Nudger provides the LLM with corrective guidance.

  ## Skill Classification

  **Read skills** (set `has_searched = true`):
  - `memory.search_memories`
  - `memory.query_entity_graph`

  **Write skills** (require `has_searched == true`):
  - `memory.save_memory`
  - `memory.extract_entities`
  - `memory.close_relation`
  - `memory.compact_conversation`

  ## State Management

  Call `new_session/0` at the start of each dispatch mission to reset state.
  Pass the state through `execute/4` to track reads across multiple calls.
  """

  alias Assistant.Skills.{Context, Executor, Result}

  require Logger

  @read_skills MapSet.new([
    "memory.search_memories",
    "memory.query_entity_graph"
  ])

  @write_skills MapSet.new([
    "memory.save_memory",
    "memory.extract_entities",
    "memory.close_relation",
    "memory.compact_conversation"
  ])

  @type session_state :: %{has_searched: boolean()}

  @doc """
  Create a fresh session state for a new dispatch mission.

  The `has_searched` flag starts as `false` and is set to `true`
  after any read skill executes successfully.
  """
  @spec new_session() :: session_state()
  def new_session do
    %{has_searched: false}
  end

  @doc """
  Execute a memory skill with search-first enforcement.

  For read skills, delegates to the underlying Executor and sets
  `has_searched = true` on success. For write skills, checks the
  `has_searched` flag first and rejects if no read has been performed.

  Non-memory skills are passed through to the Executor unchanged.

  ## Parameters

    * `skill_name` - Dot-notation skill name (e.g., "memory.save_memory")
    * `handler` - The skill handler module (or nil for template skills)
    * `args` - Skill arguments map
    * `context` - `%Skills.Context{}` for this execution
    * `session` - Current session state from `new_session/0` or prior call
    * `opts` - Options passed to the underlying Executor (e.g., timeout)

  ## Returns

    * `{:ok, %Result{}, updated_session}` - Skill executed successfully
    * `{:error, :memory_write_without_search, session}` - Write attempted without prior read
    * `{:error, reason, session}` - Underlying skill execution failed
  """
  @spec execute(String.t(), module() | nil, map(), Context.t(), session_state(), keyword()) ::
          {:ok, Result.t(), session_state()}
          | {:error, :memory_write_without_search, session_state()}
          | {:error, term(), session_state()}
  def execute(skill_name, handler, args, context, session, opts \\ []) do
    cond do
      MapSet.member?(@read_skills, skill_name) ->
        execute_read(skill_name, handler, args, context, session, opts)

      MapSet.member?(@write_skills, skill_name) ->
        execute_write(skill_name, handler, args, context, session, opts)

      true ->
        # Non-memory skill — pass through unchanged
        execute_passthrough(handler, args, context, session, opts)
    end
  end

  @doc """
  Check if a skill name is a memory domain skill (read or write).
  """
  @spec memory_skill?(String.t()) :: boolean()
  def memory_skill?(skill_name) do
    MapSet.member?(@read_skills, skill_name) or MapSet.member?(@write_skills, skill_name)
  end

  @doc """
  Check if a skill is a read (search) skill.
  """
  @spec read_skill?(String.t()) :: boolean()
  def read_skill?(skill_name) do
    MapSet.member?(@read_skills, skill_name)
  end

  @doc """
  Check if a skill is a write skill.
  """
  @spec write_skill?(String.t()) :: boolean()
  def write_skill?(skill_name) do
    MapSet.member?(@write_skills, skill_name)
  end

  # --- Private ---

  defp execute_read(skill_name, handler, args, context, session, opts) do
    case do_execute(handler, args, context, opts) do
      {:ok, %Result{} = result} ->
        Logger.debug("Memory read skill executed, search-first flag set",
          skill: skill_name,
          conversation_id: context.conversation_id
        )

        {:ok, result, %{session | has_searched: true}}

      {:error, reason} ->
        {:error, reason, session}
    end
  end

  defp execute_write(skill_name, handler, args, context, session, opts) do
    if session.has_searched do
      case do_execute(handler, args, context, opts) do
        {:ok, %Result{} = result} ->
          {:ok, result, session}

        {:error, reason} ->
          {:error, reason, session}
      end
    else
      Logger.warning("Memory write rejected — search-first violation",
        skill: skill_name,
        conversation_id: context.conversation_id
      )

      {:error, :memory_write_without_search, session}
    end
  end

  defp execute_passthrough(handler, args, context, session, opts) do
    case do_execute(handler, args, context, opts) do
      {:ok, %Result{} = result} ->
        {:ok, result, session}

      {:error, reason} ->
        {:error, reason, session}
    end
  end

  defp do_execute(nil, _args, _context, _opts) do
    # Template/stub skill with no handler — return stub result
    {:ok,
     %Result{
       status: :ok,
       content: Jason.encode!(%{result: "stub", message: "Skill handler not yet implemented."})
     }}
  end

  defp do_execute(handler, args, context, opts) do
    Executor.execute(handler, args, context, opts)
  end
end
