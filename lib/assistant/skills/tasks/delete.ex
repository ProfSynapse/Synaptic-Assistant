# lib/assistant/skills/tasks/delete.ex — Handler for tasks.delete skill.
#
# Soft-deletes a task via TaskManager.Queries.delete_task/1.
# Sets archived_at and archive_reason.
#
# Related files:
#   - lib/assistant/task_manager/queries.ex (DB operations)
#   - lib/assistant/skills/handler.ex (behaviour)
#   - priv/skills/tasks/delete.md (skill definition)

defmodule Assistant.Skills.Tasks.Delete do
  @moduledoc """
  Skill handler for soft-deleting (archiving) tasks.

  Accepts a task ID (positional) and optional --reason flag.
  Delegates to `TaskManager.Queries.delete_task/1` which sets `archived_at`
  and `archive_reason` rather than physically deleting the record.
  """

  @behaviour Assistant.Skills.Handler

  alias Assistant.Skills.Result
  alias Assistant.TaskManager.Queries

  @impl true
  def execute(flags, context) do
    task_id = flags["id"] || flags["task_id"] || flags["_positional"]

    unless task_id do
      {:ok,
       %Result{
         status: :error,
         content: "Missing required argument: task ID"
       }}
    else
      reason = flags["reason"] || "cancelled"
      opts = [archive_reason: reason]

      case Queries.delete_task(task_id, opts, context.user_id) do
        {:ok, task} ->
          {:ok,
           %Result{
             status: :ok,
             content: "Task #{task.short_id} archived (reason: #{reason}).",
             side_effects: [:task_archived],
             metadata: %{task_id: task.id, short_id: task.short_id}
           }}

        {:error, :not_found} ->
          {:ok,
           %Result{
             status: :error,
             content: "Task not found: #{task_id}"
           }}

        {:error, :unauthorized} ->
          {:ok,
           %Result{
             status: :error,
             content: "Task not found: #{task_id}"
           }}

        {:error, changeset} when is_struct(changeset, Ecto.Changeset) ->
          {:ok,
           %Result{
             status: :error,
             content: "Failed to archive task: validation error"
           }}

        {:error, reason} ->
          {:ok,
           %Result{
             status: :error,
             content: "Failed to archive task: #{inspect(reason)}"
           }}
      end
    end
  end
end
