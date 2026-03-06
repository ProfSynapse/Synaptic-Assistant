defmodule Assistant.Orchestrator.Tools.DeleteTask do
  @moduledoc """
  Orchestrator-native tool for archiving tasks directly.
  """

  alias Assistant.Orchestrator.Tools.TaskSupport
  alias Assistant.Skills.Result
  alias Assistant.TaskManager.Queries

  @archive_reasons ~w(completed cancelled superseded)

  @spec tool_definition() :: map()
  def tool_definition do
    %{
      name: "delete_task",
      description: """
      Archive a task directly. Use this when work is cancelled, superseded, or completed and should
      be closed out in the task system.\
      """,
      parameters: %{
        "type" => "object",
        "properties" => %{
          "task_ref" => %{"type" => "string", "description" => "Task short ref or UUID."},
          "reason" => %{
            "type" => "string",
            "enum" => @archive_reasons,
            "description" => "Archive reason."
          }
        },
        "required" => ["task_ref"]
      }
    }
  end

  @spec execute(map(), map()) :: {:ok, Result.t()}
  def execute(params, loop_state) do
    with {:ok, user_id} <- TaskSupport.ensure_user_id(loop_state),
         {:ok, task} <- TaskSupport.resolve_task(params["task_ref"], loop_state) do
      reason = params["reason"] || "cancelled"

      case Queries.delete_task(task.id, [archive_reason: reason], user_id) do
        {:ok, archived_task} ->
          {:ok,
           %Result{
             status: :ok,
             content: "Task #{archived_task.short_id} archived (reason: #{reason}).",
             side_effects: [:task_archived],
             metadata: %{task_id: archived_task.id, task_ref: archived_task.short_id}
           }}

        {:error, %Ecto.Changeset{} = changeset} ->
          {:ok,
           %Result{
             status: :error,
             content: "Failed to archive task: #{TaskSupport.format_changeset_errors(changeset)}"
           }}

        {:error, reason} ->
          {:ok, %Result{status: :error, content: "Failed to archive task: #{inspect(reason)}"}}
      end
    else
      {:error, reason} ->
        {:ok, %Result{status: :error, content: reason}}
    end
  end
end
