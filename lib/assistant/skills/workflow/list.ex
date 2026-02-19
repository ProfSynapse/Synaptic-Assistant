# lib/assistant/skills/workflow/list.ex — Handler for workflow.list skill.
#
# Lists all workflow prompt files in priv/workflows/. Shows name, description,
# cron schedule (if set), and channel (if set) for each workflow.
#
# Related files:
#   - lib/assistant/skills/loader.ex (frontmatter parsing)
#   - priv/skills/workflow/list.md (skill definition)

defmodule Assistant.Skills.Workflow.List do
  @moduledoc """
  Skill handler for listing all workflow prompt files.

  Scans `priv/workflows/` and returns a formatted table of workflows
  with their name, description, schedule, and channel.
  """

  @behaviour Assistant.Skills.Handler

  require Logger

  alias Assistant.Skills.{Loader, Result}
  alias Assistant.Skills.Workflow.Helpers

  @impl true
  def execute(_flags, _context) do
    dir = Helpers.resolve_workflows_dir()

    case File.ls(dir) do
      {:ok, files} ->
        workflows =
          files
          |> Enum.filter(&String.ends_with?(&1, ".md"))
          |> Enum.map(fn filename -> load_workflow(Path.join(dir, filename)) end)
          |> Enum.reject(&is_nil/1)
          |> Enum.sort_by(& &1.name)

        content = format_output(workflows)
        {:ok, %Result{status: :ok, content: content, metadata: %{count: length(workflows)}}}

      {:error, reason} ->
        Logger.warning("workflow.list: cannot read workflows directory",
          path: dir,
          reason: inspect(reason)
        )

        {:ok,
         %Result{
           status: :error,
           content: "Cannot read workflows directory: #{inspect(reason)}"
         }}
    end
  end

  # --- Private ---

  defp load_workflow(path) do
    with {:ok, content} <- File.read(path),
         {:ok, frontmatter, _body} <- Loader.parse_frontmatter(content) do
      %{
        name: frontmatter["name"] || Path.basename(path, ".md"),
        description: frontmatter["description"] || "(no description)",
        cron: frontmatter["cron"],
        channel: frontmatter["channel"],
        path: path
      }
    else
      _ -> nil
    end
  end

  defp format_output([]) do
    "No workflows found. Create one with `/workflow.create`."
  end

  defp format_output(workflows) do
    header = "Found #{length(workflows)} workflow(s):\n"

    rows =
      workflows
      |> Enum.with_index(1)
      |> Enum.map_join("\n", fn {wf, idx} ->
        schedule = if wf.cron, do: " | Cron: #{wf.cron}", else: ""
        channel = if wf.channel, do: " | Channel: #{wf.channel}", else: ""
        "#{idx}. **#{wf.name}** — #{wf.description}#{schedule}#{channel}"
      end)

    header <> rows
  end
end
