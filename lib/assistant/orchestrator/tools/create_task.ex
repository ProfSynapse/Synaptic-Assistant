defmodule Assistant.Orchestrator.Tools.CreateTask do
  @moduledoc """
  Orchestrator-native tool for creating tasks directly.
  """

  alias Assistant.Orchestrator.Tools.TaskSupport
  alias Assistant.Skills.Result
  alias Assistant.TaskManager.Queries

  @priorities ~w(critical high medium low)

  @spec tool_definition() :: map()
  def tool_definition do
    %{
      name: "create_task",
      description: """
      Create a task directly. Use this when you need to represent work in the task system,
      track a follow-up, capture a blocker, or create a durable unit of work before or after
      delegating domain work to sub-agents.\
      """,
      parameters: %{
        "type" => "object",
        "properties" => %{
          "title" => %{"type" => "string", "description" => "Short actionable task title."},
          "description" => %{
            "type" => "string",
            "description" => "Optional detailed description."
          },
          "priority" => %{
            "type" => "string",
            "enum" => @priorities,
            "description" => "Optional task priority."
          },
          "due_date" => %{
            "type" => "string",
            "description" => "Optional due date in YYYY-MM-DD format."
          },
          "tags" => %{
            "type" => "array",
            "items" => %{"type" => "string"},
            "description" => "Optional task tags."
          },
          "parent_task_ref" => %{
            "type" => "string",
            "description" => "Optional parent task ref for creating a subtask."
          }
        },
        "required" => ["title"]
      }
    }
  end

  @spec execute(map(), map()) :: {:ok, Result.t()}
  def execute(params, loop_state) do
    with {:ok, user_id} <- TaskSupport.ensure_user_id(loop_state),
         {:ok, parent_task_id} <- resolve_parent_task_id(params["parent_task_ref"], loop_state),
         {:ok, due_date} <- validate_due_date(params["due_date"]) do
      attrs =
        %{
          title: params["title"],
          creator_id: user_id,
          created_via_conversation_id: TaskSupport.conversation_id(loop_state)
        }
        |> maybe_put(:description, params["description"])
        |> maybe_put(:priority, params["priority"])
        |> maybe_put(:due_date, due_date)
        |> maybe_put(:tags, TaskSupport.parse_tags(params["tags"]))
        |> maybe_put(:parent_task_id, parent_task_id)

      case Queries.create_task(attrs) do
        {:ok, task} ->
          {:ok,
           %Result{
             status: :ok,
             content:
               "Task created: #{task.short_id} — #{task.title} (status: #{task.status}, priority: #{task.priority})",
             side_effects: [:task_created],
             metadata: %{task_id: task.id, task_ref: task.short_id}
           }}

        {:error, %Ecto.Changeset{} = changeset} ->
          {:ok,
           %Result{
             status: :error,
             content: "Failed to create task: #{TaskSupport.format_changeset_errors(changeset)}"
           }}

        {:error, reason} ->
          {:ok, %Result{status: :error, content: "Failed to create task: #{inspect(reason)}"}}
      end
    else
      {:error, reason} ->
        {:ok, %Result{status: :error, content: reason}}
    end
  end

  defp resolve_parent_task_id(nil, _loop_state), do: {:ok, nil}
  defp resolve_parent_task_id("", _loop_state), do: {:ok, nil}

  defp resolve_parent_task_id(task_ref, loop_state) do
    case TaskSupport.resolve_task(task_ref, loop_state) do
      {:ok, task} -> {:ok, task.id}
      {:error, _reason} -> {:error, "Parent task not found: #{task_ref}"}
    end
  end

  defp validate_due_date(value) do
    case TaskSupport.parse_date(value) do
      :invalid -> {:error, "Invalid due_date. Expected YYYY-MM-DD."}
      parsed -> {:ok, parsed}
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, []), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
