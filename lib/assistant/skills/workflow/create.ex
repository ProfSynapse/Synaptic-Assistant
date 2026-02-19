# lib/assistant/skills/workflow/create.ex — Handler for workflow.create skill.
#
# Creates a new workflow prompt file in priv/workflows/. Writes YAML frontmatter
# (name, description, cron, channel) plus the prompt body. Reloads the
# QuantumLoader so new cron schedules take effect immediately.
#
# Related files:
#   - lib/assistant/scheduler/quantum_loader.ex (reloaded after creation)
#   - lib/assistant/scheduler/workflow_worker.ex (executes the workflow)
#   - priv/skills/workflow/create.md (skill definition)

defmodule Assistant.Skills.Workflow.Create do
  @moduledoc """
  Skill handler for creating new workflow prompt files.

  Writes a markdown file with YAML frontmatter to `priv/workflows/`.
  If a `cron` expression is provided, the workflow will be auto-scheduled
  on next QuantumLoader reload.
  """

  @behaviour Assistant.Skills.Handler

  require Logger

  alias Assistant.Skills.Result
  alias Assistant.Skills.Workflow.Helpers

  @impl true
  def execute(flags, _context) do
    with :ok <- validate_required(flags),
         :ok <- validate_name(flags["name"]),
         :ok <- validate_field("description", flags["description"]),
         :ok <- validate_field("channel", flags["channel"]),
         :ok <- validate_cron(flags["cron"]),
         :ok <- validate_no_conflict(flags["name"]) do
      path = write_workflow(flags)
      reload_scheduler()

      Logger.info("Workflow created", name: flags["name"], path: path)

      {:ok,
       %Result{
         status: :ok,
         content: format_success(flags, path),
         side_effects: [:workflow_created],
         metadata: %{workflow_path: path, workflow_name: flags["name"]}
       }}
    else
      {:error, message} ->
        {:ok, %Result{status: :error, content: message}}
    end
  end

  # --- Private ---

  defp validate_required(flags) do
    missing =
      ["name", "description", "prompt"]
      |> Enum.reject(&Map.has_key?(flags, &1))

    if missing == [] do
      :ok
    else
      {:error, "Missing required flags: #{Enum.join(missing, ", ")}"}
    end
  end

  defp validate_name(name) do
    if Regex.match?(~r/^[a-z][a-z0-9_-]*$/, name) do
      :ok
    else
      {:error,
       "Workflow name must be lowercase alphanumeric with hyphens or underscores, starting with a letter."}
    end
  end

  defp validate_cron(nil), do: :ok

  defp validate_cron(cron) do
    case Crontab.CronExpression.Parser.parse(cron) do
      {:ok, _} ->
        :ok

      {:error, _} ->
        {:error, "Invalid cron expression: #{cron}. Expected format: \"0 8 * * *\""}
    end
  end

  defp validate_no_conflict(name) do
    path = workflow_path(name)

    if File.exists?(path) do
      {:error, "Workflow '#{name}' already exists at #{path}."}
    else
      :ok
    end
  end

  defp write_workflow(flags) do
    path = workflow_path(flags["name"])
    File.mkdir_p!(Path.dirname(path))
    content = build_content(flags)
    File.write!(path, content)
    path
  end

  defp build_content(flags) do
    frontmatter_lines = [
      ~s(name: "#{flags["name"]}"),
      ~s(description: "#{flags["description"]}")
    ]

    frontmatter_lines =
      if flags["cron"],
        do: frontmatter_lines ++ [~s(cron: "#{flags["cron"]}")],
        else: frontmatter_lines

    frontmatter_lines =
      if flags["channel"],
        do: frontmatter_lines ++ [~s(channel: "#{flags["channel"]}")],
        else: frontmatter_lines

    frontmatter_lines =
      frontmatter_lines ++
        [
          "tags:",
          "  - workflow",
          "  - scheduled"
        ]

    frontmatter = Enum.join(frontmatter_lines, "\n")

    """
    ---
    #{frontmatter}
    ---
    #{String.trim(flags["prompt"])}
    """
  end

  defp format_success(flags, path) do
    lines = [
      "Workflow '#{flags["name"]}' created at #{path}."
    ]

    lines =
      if flags["cron"],
        do: lines ++ ["Schedule: #{flags["cron"]}"],
        else: lines

    lines =
      if flags["channel"],
        do: lines ++ ["Channel: #{flags["channel"]}"],
        else: lines

    Enum.join(lines, "\n")
  end

  defp reload_scheduler do
    try do
      Assistant.Scheduler.QuantumLoader.reload()
    rescue
      _ -> :ok
    catch
      :exit, _ -> :ok
    end
  end

  defp validate_field(_field, nil), do: :ok

  defp validate_field(field, value) do
    cond do
      String.contains?(value, ["\n", "\r"]) ->
        {:error, "The #{field} field must not contain newlines."}

      String.contains?(value, "\"") ->
        {:error, "The #{field} field must not contain double-quote characters."}

      true ->
        :ok
    end
  end

  defp workflow_path(name) do
    dir = Helpers.resolve_workflows_dir()
    Path.join(dir, "#{name}.md")
  end
end
