# lib/assistant/orchestrator/tools/send_agent_update.ex — Orchestrator→sub-agent update tool.
#
# Meta-tool the orchestrator LLM calls to send updates to a paused sub-agent.
# When a sub-agent calls `request_help` and transitions to :awaiting_orchestrator,
# the orchestrator uses this tool to provide new instructions, skills, or
# context files. The sub-agent then resumes its LLM loop.
#
# Delegates to SubAgent.resume/2 which sends the update to the GenServer and
# unblocks the paused Task.
#
# Related files:
#   - lib/assistant/orchestrator/sub_agent.ex (GenServer with resume/2)
#   - lib/assistant/orchestrator/tools/get_agent_results.ex (shows awaiting status)
#   - lib/assistant/orchestrator/tools/dispatch_agent.ex (initial dispatch)
#   - lib/assistant/orchestrator/loop_runner.ex (routes tool calls)
#   - lib/assistant/orchestrator/context.ex (registers tool definition)

defmodule Assistant.Orchestrator.Tools.SendAgentUpdate do
  @moduledoc """
  Orchestrator tool for sending updates to a paused sub-agent.

  When a sub-agent calls `request_help`, it transitions to
  `:awaiting_orchestrator` and blocks until the orchestrator sends an
  update via this tool. The update can include:

    * A text message with instructions or answers
    * Additional skill names to expand the agent's tool surface
    * Additional context file paths to inject into the conversation

  ## Integration

  This module validates the request and delegates to `SubAgent.resume/2`.
  The sub-agent GenServer injects the update as a tool result for the
  pending `request_help` call and resumes the LLM loop.

  ## Usage Flow

  1. Orchestrator dispatches agent via `dispatch_agent`
  2. Agent calls `request_help` → status becomes `awaiting_orchestrator`
  3. Orchestrator sees this via `get_agent_results`
  4. Orchestrator calls `send_agent_update` with response
  5. Agent resumes with the new context
  """

  alias Assistant.Orchestrator.SubAgent

  require Logger

  @doc """
  Returns the OpenAI-compatible function tool definition for send_agent_update.
  """
  @spec tool_definition() :: map()
  def tool_definition do
    %{
      name: "send_agent_update",
      description: """
      Send an update to a paused sub-agent that called request_help. \
      The agent must be in awaiting_orchestrator state (visible via \
      get_agent_results). Provide instructions, additional skills, \
      or context files to help the agent continue.

      At least one of message, skills, or context_files must be provided.\
      """,
      parameters: %{
        "type" => "object",
        "properties" => %{
          "agent_id" => %{
            "type" => "string",
            "description" =>
              "The ID of the sub-agent to update. Must match the agent_id " <>
                "used in dispatch_agent."
          },
          "message" => %{
            "type" => "string",
            "description" =>
              "Instructions or information for the agent. This is injected " <>
                "as the tool result for the agent's request_help call."
          },
          "skills" => %{
            "type" => "array",
            "items" => %{"type" => "string"},
            "description" =>
              "Additional skill names to grant the agent. These are added " <>
                "to the agent's tool surface and their definitions are " <>
                "injected into the conversation."
          },
          "context_files" => %{
            "type" => "array",
            "items" => %{"type" => "string"},
            "description" =>
              "Additional file paths to inject into the agent's context. " <>
                "Paths relative to project root or absolute."
          }
        },
        "required" => ["agent_id"]
      }
    }
  end

  @doc """
  Validates the update request and sends it to the target sub-agent.

  ## Parameters

    * `params` - Map with agent_id and optional message, skills, context_files
    * `_context` - SkillContext (unused; included for consistent tool interface)

  ## Returns

    * `{:ok, %Result{status: :ok}}` when update sent successfully
    * `{:ok, %Result{status: :error}}` on validation failure or agent not found
  """
  @spec execute(map(), term()) :: {:ok, Assistant.Skills.Result.t()}
  def execute(params, _context) do
    with {:ok, agent_id} <- validate_agent_id(params),
         {:ok, update_map} <- validate_update(params) do
      case SubAgent.resume(agent_id, update_map) do
        :ok ->
          Logger.info("Sent update to paused sub-agent",
            agent_id: agent_id,
            has_message: update_map[:message] != nil,
            new_skills: update_map[:skills],
            new_context_files: length(update_map[:context_files] || [])
          )

          {:ok,
           %Assistant.Skills.Result{
             status: :ok,
             content:
               "Update sent to agent \"#{agent_id}\". " <>
                 "The agent is resuming. Use get_agent_results to check progress.",
             metadata: %{agent_id: agent_id}
           }}

        {:error, :not_awaiting} ->
          {:ok,
           %Assistant.Skills.Result{
             status: :error,
             content:
               "Agent \"#{agent_id}\" is not awaiting orchestrator input. " <>
                 "Only agents that called request_help can receive updates. " <>
                 "Check the agent's status with get_agent_results."
           }}

        {:error, :not_found} ->
          {:ok,
           %Assistant.Skills.Result{
             status: :error,
             content:
               "Agent \"#{agent_id}\" not found. It may have already " <>
                 "completed or was never dispatched. Check agent_ids " <>
                 "with get_agent_results."
           }}
      end
    else
      {:error, reason} ->
        {:ok,
         %Assistant.Skills.Result{
           status: :error,
           content: reason
         }}
    end
  end

  # --- Validation ---

  defp validate_agent_id(params) do
    case params["agent_id"] do
      id when is_binary(id) and id != "" ->
        {:ok, id}

      _ ->
        {:error, "Missing required field: agent_id"}
    end
  end

  defp validate_update(params) do
    message = params["message"]
    skills = params["skills"]
    context_files = params["context_files"]

    has_message = is_binary(message) and message != ""
    has_skills = is_list(skills) and skills != []
    has_context_files = is_list(context_files) and context_files != []

    if not has_message and not has_skills and not has_context_files do
      {:error,
       "At least one of message, skills, or context_files must be provided. " <>
         "The agent needs something to continue with."}
    else
      update =
        %{}
        |> maybe_put(:message, message, has_message)
        |> maybe_put(:skills, skills, has_skills)
        |> maybe_put(:context_files, context_files, has_context_files)

      {:ok, update}
    end
  end

  defp maybe_put(map, _key, _value, false), do: map
  defp maybe_put(map, key, value, true), do: Map.put(map, key, value)
end
