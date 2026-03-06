# lib/assistant/orchestrator/tools/cancel_agent.ex — Orchestrator hard-stop tool.
#
# Meta-tool the orchestrator LLM calls to immediately terminate a sub-agent.
# Unlike send_agent_update, this is not a resume/help path. It stops the
# target agent right away and preserves a truncated transcript snapshot so the
# orchestrator can choose whether to relaunch a fresh agent later.

defmodule Assistant.Orchestrator.Tools.CancelAgent do
  @moduledoc """
  Orchestrator tool for immediately terminating a sub-agent.

  The target agent ends in `:cancelled` state and is not resumed in place.
  If the orchestrator wants to continue the work, it should dispatch a new
  sub-agent using the cancelled agent's last snapshot as context.
  """

  alias Assistant.Orchestrator.SubAgent

  @doc """
  Returns the OpenAI-compatible function tool definition for cancel_agent.
  """
  @spec tool_definition() :: map()
  def tool_definition do
    %{
      name: "cancel_agent",
      description: """
      Immediately terminate a sub-agent that is running or awaiting input.
      Use this when the user changes their mind, an agent is going off the rails,
      or the work is no longer needed. This is a hard stop, not a pause.\
      """,
      parameters: %{
        "type" => "object",
        "properties" => %{
          "agent_id" => %{
            "type" => "string",
            "description" => "The ID of the sub-agent to terminate."
          },
          "reason" => %{
            "type" => "string",
            "description" =>
              "Why the agent is being cancelled. Include user intent or orchestration rationale."
          }
        },
        "required" => ["agent_id"]
      }
    }
  end

  @doc """
  Cancels a sub-agent immediately.
  """
  @spec execute(map(), term()) :: {:ok, Assistant.Skills.Result.t()}
  def execute(params, _context) do
    case params["agent_id"] do
      id when is_binary(id) and id != "" ->
        reason = params["reason"] || "Cancelled by orchestrator."

        case SubAgent.cancel(id, reason) do
          :ok ->
            {:ok,
             %Assistant.Skills.Result{
               status: :ok,
               content:
                 "Agent \"#{id}\" was cancelled immediately. " <>
                   "If you still need the work, dispatch a fresh agent from its last snapshot."
             }}

          {:error, :already_terminal, status} ->
            {:ok,
             %Assistant.Skills.Result{
               status: :error,
               content:
                 "Agent \"#{id}\" is already in terminal state #{status} and cannot be cancelled."
             }}

          {:error, :not_found} ->
            {:ok,
             %Assistant.Skills.Result{
               status: :error,
               content: "Agent \"#{id}\" not found. It may have already exited."
             }}
        end

      _ ->
        {:ok,
         %Assistant.Skills.Result{
           status: :error,
           content: "Missing required field: agent_id"
         }}
    end
  end
end
