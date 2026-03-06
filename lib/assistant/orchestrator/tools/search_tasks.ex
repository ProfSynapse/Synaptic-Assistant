defmodule Assistant.Orchestrator.Tools.SearchTasks do
  @moduledoc """
  Orchestrator-native tool for searching tasks directly.
  """

  alias Assistant.Orchestrator.Tools.TaskSupport
  alias Assistant.Skills.Result
  alias Assistant.TaskManager.Queries

  @spec tool_definition() :: map()
  def tool_definition do
    %{
      name: "search_tasks",
      description: """
      Search tasks directly. Use this to inspect current work, find blockers, locate follow-ups,
      or review prior tasks before dispatching or updating work.\
      """,
      parameters: %{
        "type" => "object",
        "properties" => %{
          "query" => %{"type" => "string", "description" => "Optional text query."},
          "status" => %{"type" => "string", "description" => "Optional status filter."},
          "priority" => %{"type" => "string", "description" => "Optional priority filter."},
          "tags" => %{
            "type" => "array",
            "items" => %{"type" => "string"},
            "description" => "Optional tag filter."
          },
          "due_before" => %{
            "type" => "string",
            "description" => "Optional YYYY-MM-DD upper bound."
          },
          "due_after" => %{
            "type" => "string",
            "description" => "Optional YYYY-MM-DD lower bound."
          },
          "limit" => %{"type" => "integer", "description" => "Optional result limit."}
        },
        "required" => []
      }
    }
  end

  @spec execute(map(), map()) :: {:ok, Result.t()}
  def execute(params, loop_state) do
    with {:ok, user_id} <- TaskSupport.ensure_user_id(loop_state),
         {:ok, due_before} <- validate_date("due_before", params["due_before"]),
         {:ok, due_after} <- validate_date("due_after", params["due_after"]) do
      tasks =
        Queries.search_tasks(
          user_id: user_id,
          query: params["query"],
          status: params["status"],
          priority: params["priority"],
          tags: TaskSupport.parse_tags(params["tags"]),
          due_before: due_before,
          due_after: due_after,
          limit: normalize_limit(params["limit"])
        )

      content =
        case tasks do
          [] ->
            "No tasks found matching the given criteria."

          tasks ->
            rows =
              Enum.map_join(tasks, "\n", fn task ->
                "- [#{task.short_id}] #{task.title} (#{task.status}/#{task.priority})#{format_due(task.due_date)}"
              end)

            "Found #{length(tasks)} task(s):\n#{rows}"
        end

      {:ok, %Result{status: :ok, content: content, metadata: %{count: length(tasks)}}}
    else
      {:error, reason} ->
        {:ok, %Result{status: :error, content: reason}}
    end
  end

  defp validate_date(_field, nil), do: {:ok, nil}
  defp validate_date(_field, ""), do: {:ok, nil}

  defp validate_date(field, value) do
    case TaskSupport.parse_date(value) do
      :invalid -> {:error, "Invalid #{field}. Expected YYYY-MM-DD."}
      parsed -> {:ok, parsed}
    end
  end

  defp normalize_limit(limit) when is_integer(limit) and limit > 0, do: limit
  defp normalize_limit(_), do: 20

  defp format_due(nil), do: ""
  defp format_due(due_date), do: " due:#{Date.to_iso8601(due_date)}"
end
