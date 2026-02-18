# lib/assistant/skills/tasks/create.ex — Handler for tasks.create skill.
#
# Creates a new task via TaskManager.Queries.create_task/1.
# Parses CLI flags for title, description, priority, due date, tags, and parent.
#
# Related files:
#   - lib/assistant/task_manager/queries.ex (DB operations)
#   - lib/assistant/skills/handler.ex (behaviour)
#   - priv/skills/tasks/create.md (skill definition)

defmodule Assistant.Skills.Tasks.Create do
  @moduledoc """
  Skill handler for creating tasks.

  Accepts CLI flags, validates required fields, calls
  `TaskManager.Queries.create_task/1`, and returns a formatted result.
  """

  @behaviour Assistant.Skills.Handler

  alias Assistant.Skills.Result
  alias Assistant.TaskManager.Queries

  @impl true
  def execute(flags, _context) do
    title = flags["title"]

    unless title do
      {:ok,
       %Result{
         status: :error,
         content: "Missing required flag: --title"
       }}
    else
      attrs =
        %{title: title}
        |> maybe_put(:description, flags["description"])
        |> maybe_put(:priority, flags["priority"])
        |> maybe_put(:tags, parse_tags(flags["tags"]))
        |> maybe_put(:due_date, parse_date(flags["due"]))
        |> maybe_put(:parent_task_id, flags["parent"])

      case Queries.create_task(attrs) do
        {:ok, task} ->
          content = """
          Task created successfully.

          ID: #{task.id}
          Short ID: #{task.short_id}
          Title: #{task.title}
          Status: #{task.status}
          Priority: #{task.priority}\
          #{if task.due_date, do: "\nDue: #{task.due_date}", else: ""}\
          #{if task.tags != [], do: "\nTags: #{Enum.join(task.tags, ", ")}", else: ""}
          """

          {:ok,
           %Result{
             status: :ok,
             content: String.trim(content),
             side_effects: [:task_created],
             metadata: %{task_id: task.id, short_id: task.short_id}
           }}

        {:error, changeset} when is_struct(changeset, Ecto.Changeset) ->
          errors = format_changeset_errors(changeset)

          {:ok,
           %Result{
             status: :error,
             content: "Failed to create task: #{errors}"
           }}

        {:error, reason} ->
          {:ok,
           %Result{
             status: :error,
             content: "Failed to create task: #{inspect(reason)}"
           }}
      end
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
