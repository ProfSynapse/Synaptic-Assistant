# lib/assistant/orchestrator/tools/dispatch_agent.ex — Sub-agent dispatch tool.
#
# Meta-tool the orchestrator LLM calls to delegate a focused task to a
# sub-agent. Creates an ExecutionLog record in the database for audit,
# validates the requested skills against the registry, checks circuit
# breaker limits (per-turn agent limit), and returns an agent_id for
# tracking via get_agent_results.
#
# Does NOT execute the agent inline — returns dispatch params that the
# Engine's AgentScheduler will use to actually spawn the sub-agent Task.

defmodule Assistant.Orchestrator.Tools.DispatchAgent do
  @moduledoc """
  Orchestrator tool for delegating a focused task to a sub-agent.

  The orchestrator calls this after discovering skills via `get_skill`.
  Each dispatch creates an `ExecutionLog` record for audit and returns
  a structured dispatch confirmation.

  The actual sub-agent execution is handled by the Engine's scheduler,
  not by this module. This module validates the dispatch request, checks
  limits, and persists the execution log entry.

  ## Dispatch Flow

  1. Validate required fields (agent_id, mission, skills)
  2. Verify all requested skills exist in the registry
  3. Check per-turn agent dispatch limit via CircuitBreaker
  4. Create ExecutionLog record with status "pending"
  5. Return dispatch params for the AgentScheduler
  """

  alias Assistant.Repo
  alias Assistant.Resilience.CircuitBreaker
  alias Assistant.Schemas.ExecutionLog
  alias Assistant.Skills.Registry

  require Logger

  @default_max_tool_calls 5

  @doc """
  Returns the OpenAI-compatible function tool definition for dispatch_agent.
  """
  @spec tool_definition() :: map()
  def tool_definition do
    %{
      name: "dispatch_agent",
      description: """
      Dispatch a sub-agent to execute a focused task. The agent receives the \
      skills it needs and a clear mission. Use this after calling get_skill \
      to understand available capabilities.

      You can dispatch multiple agents at once — they will run in parallel \
      unless you specify dependencies via depends_on.

      Each agent returns a result when complete. Use get_agent_results to \
      collect outputs.\
      """,
      parameters: %{
        "type" => "object",
        "properties" => %{
          "agent_id" => %{
            "type" => "string",
            "description" =>
              "A unique identifier for this agent (e.g., \"email_agent\", " <>
                "\"task_search\"). Used for dependency references and result tracking."
          },
          "mission" => %{
            "type" => "string",
            "description" =>
              "Clear, specific instructions for what the agent should accomplish. " <>
                "Be explicit about inputs, expected outputs, and success criteria."
          },
          "skills" => %{
            "type" => "array",
            "items" => %{"type" => "string"},
            "description" =>
              "List of skill names the agent can use (e.g., [\"tasks.search\", " <>
                "\"email.send\"]). The agent only sees these skills."
          },
          "context" => %{
            "type" => "string",
            "description" =>
              "Additional context the agent needs (e.g., search results from " <>
                "a prior agent, user preferences). Keep concise. Optional."
          },
          "depends_on" => %{
            "type" => "array",
            "items" => %{"type" => "string"},
            "description" =>
              "Agent IDs this agent must wait for before starting. Their " <>
                "results are injected into this agent's context. Optional — " <>
                "omit for parallel execution."
          },
          "max_tool_calls" => %{
            "type" => "integer",
            "description" =>
              "Maximum tool calls this agent can make. Default: #{@default_max_tool_calls}. " <>
                "Use higher for complex multi-step tasks."
          },
          "model_override" => %{
            "type" => "string",
            "description" =>
              "Override the LLM model for this agent (e.g., " <>
                "\"anthropic/claude-haiku-4-5-20251001\" for simple tasks). " <>
                "Optional — defaults to the orchestrator's model."
          }
        },
        "required" => ["agent_id", "mission", "skills"]
      }
    }
  end

  @doc """
  Validates the dispatch request, checks limits, creates an execution log,
  and returns structured dispatch params.

  ## Parameters

    * `params` - Map with agent_id, mission, skills, and optional fields
    * `context` - SkillContext with conversation_id for the execution log

  ## Returns

    * `{:ok, %Result{}}` on success with dispatch params in metadata
    * `{:ok, %Result{status: :error}}` on validation failure or limit exceeded
  """
  @spec execute(map(), Assistant.Skills.Context.t()) :: {:ok, Assistant.Skills.Result.t()}
  def execute(params, context) do
    with {:ok, validated} <- validate_params(params),
         {:ok, _} <- verify_skills_exist(validated.skills),
         {:ok, execution_log} <- create_execution_log(validated, context) do
      dispatch_params = build_dispatch_params(validated, execution_log)

      Logger.info("Agent dispatched",
        agent_id: validated.agent_id,
        skills: validated.skills,
        conversation_id: context.conversation_id,
        execution_log_id: execution_log.id
      )

      {:ok,
       %Assistant.Skills.Result{
         status: :ok,
         content:
           "Agent \"#{validated.agent_id}\" dispatched with skills: " <>
             Enum.join(validated.skills, ", "),
         metadata: %{
           dispatch: dispatch_params,
           execution_log_id: execution_log.id
         }
       }}
    else
      {:error, :missing_fields, fields} ->
        {:ok,
         %Assistant.Skills.Result{
           status: :error,
           content: "Missing required fields: #{Enum.join(fields, ", ")}"
         }}

      {:error, :unknown_skills, unknown} ->
        {:ok,
         %Assistant.Skills.Result{
           status: :error,
           content:
             "Unknown skills: #{Enum.join(unknown, ", ")}. " <>
               "Call get_skill to discover available skills."
         }}

      {:error, :db_error, reason} ->
        Logger.error("Failed to create execution log",
          agent_id: params["agent_id"],
          reason: inspect(reason)
        )

        {:ok,
         %Assistant.Skills.Result{
           status: :error,
           content: "Internal error: failed to create execution log."
         }}
    end
  end

  @doc """
  Checks whether additional agents can be dispatched within per-turn limits.

  This is a convenience wrapper around `CircuitBreaker.check_turn_agents/2`
  for the Engine to call before processing dispatch_agent tool calls.

  Returns `{:ok, updated_turn_state}` or `{:error, :limit_exceeded, details}`.
  """
  @spec check_dispatch_limit(map(), pos_integer()) ::
          {:ok, map()} | {:error, :limit_exceeded, map()}
  def check_dispatch_limit(turn_state, agent_count \\ 1) do
    CircuitBreaker.check_turn_agents(turn_state, agent_count)
  end

  # --- Validation ---

  defp validate_params(params) do
    agent_id = params["agent_id"]
    mission = params["mission"]
    skills = params["skills"]

    missing =
      []
      |> maybe_missing("agent_id", agent_id)
      |> maybe_missing("mission", mission)
      |> maybe_missing("skills", skills)

    cond do
      missing != [] ->
        {:error, :missing_fields, missing}

      not is_binary(agent_id) or agent_id == "" ->
        {:error, :missing_fields, ["agent_id"]}

      not is_binary(mission) or mission == "" ->
        {:error, :missing_fields, ["mission"]}

      not is_list(skills) or skills == [] ->
        {:error, :missing_fields, ["skills"]}

      true ->
        {:ok,
         %{
           agent_id: agent_id,
           mission: mission,
           skills: skills,
           context: params["context"],
           depends_on: params["depends_on"] || [],
           max_tool_calls: params["max_tool_calls"] || @default_max_tool_calls,
           model_override: params["model_override"]
         }}
    end
  end

  defp maybe_missing(acc, field, nil), do: [field | acc]
  defp maybe_missing(acc, _field, _value), do: acc

  defp verify_skills_exist(skill_names) do
    unknown =
      Enum.filter(skill_names, fn name ->
        not Registry.skill_exists?(name)
      end)

    case unknown do
      [] -> {:ok, skill_names}
      _ -> {:error, :unknown_skills, unknown}
    end
  end

  # --- Persistence ---

  defp create_execution_log(validated, context) do
    attrs = %{
      skill_id: "dispatch:#{validated.agent_id}",
      conversation_id: context.conversation_id,
      parameters: %{
        agent_id: validated.agent_id,
        mission: validated.mission,
        skills: validated.skills,
        depends_on: validated.depends_on,
        max_tool_calls: validated.max_tool_calls,
        model_override: validated.model_override
      },
      status: "pending",
      started_at: DateTime.utc_now()
    }

    case %ExecutionLog{} |> ExecutionLog.changeset(attrs) |> Repo.insert() do
      {:ok, log} -> {:ok, log}
      {:error, changeset} -> {:error, :db_error, changeset}
    end
  end

  # --- Dispatch Params ---

  defp build_dispatch_params(validated, execution_log) do
    %{
      agent_id: validated.agent_id,
      mission: validated.mission,
      skills: validated.skills,
      context: validated.context,
      depends_on: validated.depends_on,
      max_tool_calls: validated.max_tool_calls,
      model_override: validated.model_override,
      execution_log_id: execution_log.id
    }
  end
end
