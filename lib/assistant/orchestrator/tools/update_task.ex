defmodule Assistant.Orchestrator.Tools.UpdateTask do
  @moduledoc """
  Orchestrator-native tool for updating tasks directly.
  """

  alias Assistant.Orchestrator.Tools.TaskSupport
  alias Assistant.Skills.Result
  alias Assistant.TaskManager.Queries

  @spec tool_definition() :: map()
  def tool_definition do
    %{
      name: "update_task",
      description: """
      Update an existing task directly. Use this to change status, priority, title, description,
      due dates, or tags based on new information from the user or sub-agents.\
      """,
      parameters: %{
        "type" => "object",
        "properties" => %{
          "task_ref" => %{"type" => "string", "description" => "Task short ref or UUID."},
          "status" => %{"type" => "string", "description" => "Optional new status."},
          "priority" => %{"type" => "string", "description" => "Optional new priority."},
          "title" => %{"type" => "string", "description" => "Optional new title."},
          "description" => %{"type" => "string", "description" => "Optional new description."},
          "due_date" => %{
            "type" => "string",
            "description" => "Optional new due date in YYYY-MM-DD format."
          },
          "tags" => %{
            "type" => "array",
            "items" => %{"type" => "string"},
            "description" => "Replace tags entirely with this list."
          },
          "add_tags" => %{
            "type" => "array",
            "items" => %{"type" => "string"},
            "description" => "Add tags without replacing the existing list."
          },
          "remove_tags" => %{
            "type" => "array",
            "items" => %{"type" => "string"},
            "description" => "Remove specific tags."
          }
        },
        "required" => ["task_ref"]
      }
    }
  end

  @spec execute(map(), map()) :: {:ok, Result.t()}
  def execute(params, loop_state) do
    with {:ok, user_id} <- TaskSupport.ensure_user_id(loop_state),
         {:ok, task} <- TaskSupport.resolve_task(params["task_ref"], loop_state),
         {:ok, due_date} <- validate_due_date(params["due_date"]),
         {:ok, attrs} <- build_attrs(params, task, loop_state, user_id, due_date) do
      if attrs == %{} do
        {:ok,
         %Result{
           status: :error,
           content: "No fields to update. Provide at least one task field."
         }}
      else
        case Queries.update_task(task.id, attrs, user_id) do
          {:ok, updated_task} ->
            changed_fields =
              attrs
              |> Map.drop([:changed_by_user_id, :changed_via_conversation_id])
              |> Map.keys()
              |> Enum.map_join(", ", &Atom.to_string/1)

            {:ok,
             %Result{
               status: :ok,
               content: "Task #{updated_task.short_id} updated. Changed: #{changed_fields}",
               side_effects: [:task_updated],
               metadata: %{task_id: updated_task.id, task_ref: updated_task.short_id}
             }}

          {:error, %Ecto.Changeset{} = changeset} ->
            {:ok,
             %Result{
               status: :error,
               content: "Failed to update task: #{TaskSupport.format_changeset_errors(changeset)}"
             }}

          {:error, reason} ->
            {:ok, %Result{status: :error, content: "Failed to update task: #{inspect(reason)}"}}
        end
      end
    else
      {:error, reason} ->
        {:ok, %Result{status: :error, content: reason}}
    end
  end

  defp build_attrs(params, task, loop_state, user_id, due_date) do
    tags =
      case TaskSupport.parse_tags(params["tags"]) do
        nil -> merge_tags(task.tags || [], params["add_tags"], params["remove_tags"])
        replacement -> replacement
      end

    user_attrs =
      %{}
      |> maybe_put(:status, params["status"])
      |> maybe_put(:priority, params["priority"])
      |> maybe_put(:title, params["title"])
      |> maybe_put(:description, params["description"])
      |> maybe_put(:due_date, due_date)
      |> maybe_put(:tags, tags)

    attrs =
      user_attrs
      |> maybe_put(:changed_by_user_id, user_id)
      |> maybe_put(:changed_via_conversation_id, TaskSupport.conversation_id(loop_state))

    if user_attrs == %{} do
      {:ok, %{}}
    else
      {:ok, attrs}
    end
  end

  defp merge_tags(current_tags, add_tags, remove_tags) do
    add_tags = TaskSupport.parse_tags(add_tags)
    remove_tags = TaskSupport.parse_tags(remove_tags)

    cond do
      add_tags == nil and remove_tags == nil ->
        nil

      true ->
        current_tags
        |> Kernel.++(add_tags || [])
        |> Enum.uniq()
        |> then(fn tags ->
          if remove_tags, do: tags -- remove_tags, else: tags
        end)
    end
  end

  defp validate_due_date(nil), do: {:ok, nil}
  defp validate_due_date(""), do: {:ok, nil}

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
