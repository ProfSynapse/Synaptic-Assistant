# lib/assistant/skills/tasks/search.ex — Handler for tasks.search skill.
#
# Searches tasks via TaskManager.Queries.search_tasks/1 using FTS + filters.
# Parses CLI flags for query text, status, priority, tags, and date ranges.
#
# Related files:
#   - lib/assistant/task_manager/queries.ex (DB operations)
#   - lib/assistant/skills/handler.ex (behaviour)
#   - priv/skills/tasks/search.md (skill definition)

defmodule Assistant.Skills.Tasks.Search do
  @moduledoc """
  Skill handler for searching tasks.

  Supports full-text search and structured filters (status, priority, tags,
  date ranges). Returns formatted results for LLM context.
  """

  @behaviour Assistant.Skills.Handler

  alias Assistant.Skills.Result
  alias Assistant.TaskManager.Queries

  @impl true
  def execute(flags, _context) do
    opts =
      []
      |> maybe_add(:query, flags["query"])
      |> maybe_add(:status, flags["status"])
      |> maybe_add(:priority, flags["priority"])
      |> maybe_add(:assignee_id, flags["assignee"])
      |> maybe_add(:tags, parse_tags(flags["tags"]))
      |> maybe_add(:due_before, parse_date(flags["due_before"] || flags["due-before"]))
      |> maybe_add(:due_after, parse_date(flags["due_after"] || flags["due-after"]))

    tasks = Queries.search_tasks(opts)

    content =
      if tasks == [] do
        "No tasks found matching the given criteria."
      else
        header = "Found #{length(tasks)} task(s):\n"

        rows =
          tasks
          |> Enum.map(&format_task_row/1)
          |> Enum.join("\n")

        header <> rows
      end

    {:ok,
     %Result{
       status: :ok,
       content: content,
       metadata: %{count: length(tasks)}
     }}
  end

  defp format_task_row(task) do
    due = if task.due_date, do: " | Due: #{task.due_date}", else: ""
    tags = if task.tags != [], do: " | Tags: #{Enum.join(task.tags, ", ")}", else: ""

    "- [#{task.short_id}] #{task.title} (#{task.status}/#{task.priority})#{due}#{tags}"
  end

  defp maybe_add(opts, _key, nil), do: opts
  defp maybe_add(opts, key, value), do: Keyword.put(opts, key, value)

  defp parse_tags(nil), do: nil
  defp parse_tags(tags) when is_list(tags), do: tags

  defp parse_tags(tags) when is_binary(tags) do
    tags
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp parse_date(nil), do: nil

  defp parse_date(date_str) when is_binary(date_str) do
    case Date.from_iso8601(date_str) do
      {:ok, date} -> date
      {:error, _} -> nil
    end
  end
end
