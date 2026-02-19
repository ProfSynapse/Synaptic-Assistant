# lib/assistant/skills/tasks/update.ex — Handler for tasks.update skill.
#
# Updates a task's fields via TaskManager.Queries.update_task/2.
# Supports updating status, priority, title, description, assignee, and tags.
# Tag modifications support --add-tag and --remove-tag for incremental changes.
#
# Related files:
#   - lib/assistant/task_manager/queries.ex (DB operations)
#   - lib/assistant/skills/handler.ex (behaviour)
#   - priv/skills/tasks/update.md (skill definition)

defmodule Assistant.Skills.Tasks.Update do
  @moduledoc """
  Skill handler for updating task fields.

  Accepts a task ID (positional) and flags for fields to change. Supports
  both full replacement and incremental tag modifications.
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
      attrs = build_update_attrs(flags, task_id, context)

      if attrs == %{} do
        {:ok,
         %Result{
           status: :error,
           content: "No fields to update. Provide at least one flag (--status, --priority, --title, etc.)"
         }}
      else
        case Queries.update_task(task_id, attrs, context.user_id) do
          {:ok, task} ->
            changed_fields = Map.keys(attrs) |> Enum.map_join(", ", &Atom.to_string/1)

            {:ok,
             %Result{
               status: :ok,
               content: "Task #{task.short_id} updated. Changed: #{changed_fields}",
               side_effects: [:task_updated],
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
            errors = format_changeset_errors(changeset)

            {:ok,
             %Result{
               status: :error,
               content: "Failed to update task: #{errors}"
             }}

          {:error, reason} ->
            {:ok,
             %Result{
               status: :error,
               content: "Failed to update task: #{inspect(reason)}"
             }}
        end
      end
    end
  end

  defp build_update_attrs(flags, task_id, context) do
    attrs = %{}

    attrs = maybe_put(attrs, :status, flags["status"])
    attrs = maybe_put(attrs, :priority, flags["priority"])
    attrs = maybe_put(attrs, :title, flags["title"])
    attrs = maybe_put(attrs, :description, flags["description"])
    attrs = maybe_put(attrs, :assignee_id, flags["assign"])
    attrs = maybe_put(attrs, :due_date, parse_date(flags["due"]))

    # Tag modifications: --add-tag and --remove-tag for incremental changes
    attrs = apply_tag_changes(attrs, flags, task_id, context.user_id)

    # Audit metadata (not stored on the task, but passed to history logging)
    attrs = maybe_put(attrs, :changed_by_user_id, context.user_id)
    attrs = maybe_put(attrs, :changed_via_conversation_id, context.conversation_id)

    attrs
  end

  defp apply_tag_changes(attrs, flags, task_id, user_id) do
    add_tags = parse_tags(flags["add_tag"] || flags["add-tag"])
    remove_tags = parse_tags(flags["remove_tag"] || flags["remove-tag"])

    if add_tags || remove_tags do
      case Queries.get_task(task_id, user_id) do
        {:ok, task} ->
          current_tags = task.tags || []
          new_tags = current_tags

          new_tags =
            if add_tags do
              Enum.uniq(new_tags ++ add_tags)
            else
              new_tags
            end

          new_tags =
            if remove_tags do
              new_tags -- remove_tags
            else
              new_tags
            end

          Map.put(attrs, :tags, new_tags)

        {:error, _} ->
          attrs
      end
    else
      attrs
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

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

  defp format_changeset_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
    |> Enum.map_join("; ", fn {field, msgs} -> "#{field}: #{Enum.join(msgs, ", ")}" end)
  end
end
