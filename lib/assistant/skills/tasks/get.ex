# lib/assistant/skills/tasks/get.ex — Handler for tasks.get skill.
#
# Fetches a single task by UUID or short_id via TaskManager.Queries.get_task/1.
# Returns full task details including subtasks, comments, and history.
#
# Related files:
#   - lib/assistant/task_manager/queries.ex (DB operations)
#   - lib/assistant/skills/handler.ex (behaviour)
#   - priv/skills/tasks/get.md (skill definition)

defmodule Assistant.Skills.Tasks.Get do
  @moduledoc """
  Skill handler for fetching a single task with full details.

  Accepts a task ID (UUID) or short_id (e.g., "T-001") as a positional argument.
  Returns the task with its subtasks, comments, and audit history.
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
         content: "Missing required argument: task ID or short_id (e.g., T-001)"
       }}
    else
      case Queries.get_task(task_id, context.user_id) do
        {:ok, task} ->
          {:ok,
           %Result{
             status: :ok,
             content: format_task_detail(task),
             metadata: %{task_id: task.id, short_id: task.short_id}
           }}

        {:error, :not_found} ->
          {:ok,
           %Result{
             status: :error,
             content: "Task not found: #{task_id}"
           }}
      end
    end
  end

  defp format_task_detail(task) do
    sections = [
      "## Task #{task.short_id}",
      "",
      "**Title:** #{task.title}",
      "**Status:** #{task.status}",
      "**Priority:** #{task.priority}",
      if(task.description, do: "**Description:** #{task.description}", else: nil),
      if(task.due_date, do: "**Due:** #{task.due_date}", else: nil),
      if(task.tags != [], do: "**Tags:** #{Enum.join(task.tags, ", ")}", else: nil),
      if(task.started_at, do: "**Started:** #{task.started_at}", else: nil),
      if(task.completed_at, do: "**Completed:** #{task.completed_at}", else: nil),
      if(task.archived_at,
        do: "**Archived:** #{task.archived_at} (#{task.archive_reason})",
        else: nil
      ),
      "",
      format_subtasks(task.subtasks),
      format_comments(task.comments),
      format_history(task.history)
    ]

    sections
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
    |> String.trim()
  end

  defp format_subtasks([]), do: nil

  defp format_subtasks(subtasks) do
    header = "### Subtasks (#{length(subtasks)})"

    rows =
      Enum.map_join(subtasks, "\n", fn st ->
        "- [#{st.short_id}] #{st.title} (#{st.status})"
      end)

    header <> "\n" <> rows
  end

  defp format_comments([]), do: nil

  defp format_comments(comments) do
    header = "### Comments (#{length(comments)})"

    rows =
      Enum.map_join(comments, "\n", fn c ->
        author = if c.author, do: c.author.display_name || "User", else: "Assistant"
        "- [#{author}] #{c.content}"
      end)

    header <> "\n" <> rows
  end

  defp format_history([]), do: nil

  defp format_history(history) do
    header = "### History (#{length(history)} entries)"

    rows =
      history
      |> Enum.take(10)
      |> Enum.map_join("\n", fn h ->
        "- #{h.field_changed}: #{h.old_value || "(empty)"} -> #{h.new_value || "(empty)"}"
      end)

    trailer = if length(history) > 10, do: "\n  ... and #{length(history) - 10} more", else: ""
    header <> "\n" <> rows <> trailer
  end
end
