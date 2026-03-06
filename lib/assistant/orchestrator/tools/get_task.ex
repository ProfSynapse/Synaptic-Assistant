defmodule Assistant.Orchestrator.Tools.GetTask do
  @moduledoc """
  Orchestrator-native tool for retrieving task details directly.
  """

  alias Assistant.Orchestrator.Tools.TaskSupport
  alias Assistant.Skills.Result

  @spec tool_definition() :: map()
  def tool_definition do
    %{
      name: "get_task",
      description:
        "Fetch a task by task_ref and inspect its current state, subtasks, comments, and history.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "task_ref" => %{
            "type" => "string",
            "description" => "Task short ref or UUID."
          }
        },
        "required" => ["task_ref"]
      }
    }
  end

  @spec execute(map(), map()) :: {:ok, Result.t()}
  def execute(params, loop_state) do
    case TaskSupport.resolve_task(params["task_ref"], loop_state) do
      {:ok, task} ->
        subtasks = length(task.subtasks || [])
        comments = length(task.comments || [])
        history = length(task.history || [])

        content = """
        Task #{task.short_id}
        Title: #{task.title}
        Status: #{task.status}
        Priority: #{task.priority}#{format_due(task.due_date)}#{format_tags(task.tags)}
        Subtasks: #{subtasks}
        Comments: #{comments}
        History entries: #{history}\
        #{format_description(task.description)}
        """

        {:ok,
         %Result{
           status: :ok,
           content: String.trim(content),
           metadata: %{task_id: task.id, task_ref: task.short_id}
         }}

      {:error, reason} ->
        {:ok, %Result{status: :error, content: reason}}
    end
  end

  defp format_due(nil), do: ""
  defp format_due(due_date), do: "\nDue: #{Date.to_iso8601(due_date)}"

  defp format_tags([]), do: ""
  defp format_tags(nil), do: ""
  defp format_tags(tags), do: "\nTags: #{Enum.join(tags, ", ")}"

  defp format_description(nil), do: ""
  defp format_description(""), do: ""
  defp format_description(description), do: "\nDescription: #{description}"
end
