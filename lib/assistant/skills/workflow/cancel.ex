# lib/assistant/skills/workflow/cancel.ex — Handler for workflow.cancel skill.
#
# Removes a scheduled workflow by deleting its Quantum job and optionally
# deleting the workflow file itself. Reloads the QuantumLoader after removal.
#
# Related files:
#   - lib/assistant/scheduler/quantum_loader.ex (cron job management)
#   - priv/skills/workflow/cancel.md (skill definition)

defmodule Assistant.Skills.Workflow.Cancel do
  @moduledoc """
  Skill handler for canceling a scheduled workflow.

  Removes the Quantum cron job for the named workflow. With `--delete`,
  also removes the workflow file from disk.
  """

  @behaviour Assistant.Skills.Handler

  require Logger

  alias Assistant.Skills.Result
  alias Assistant.Skills.Workflow.Helpers

  @impl true
  def execute(flags, _context) do
    name = flags["name"]

    unless name do
      {:ok,
       %Result{
         status: :error,
         content: "Missing required flag: --name"
       }}
    else
      unless valid_workflow_name?(name) do
        {:ok,
         %Result{
           status: :error,
           content:
             "Invalid workflow name: must be lowercase alphanumeric with hyphens or underscores, starting with a letter."
         }}
      else
        path = workflow_path(name)

        if File.exists?(path) do
          cancel_workflow(name, path, flags)
        else
          {:ok,
           %Result{
             status: :error,
             content:
               "Workflow '#{name}' not found. Use `/workflow.list` to see available workflows."
           }}
        end
      end
    end
  end

  # --- Private ---

  defp cancel_workflow(name, path, flags) do
    # Remove Quantum job via QuantumLoader (uses ref-based lookup, no atoms)
    Assistant.Scheduler.QuantumLoader.cancel(name)

    # Optionally delete the file
    deleted_file? = delete_flag?(flags) && delete_file(path)

    Logger.info("workflow.cancel: canceled workflow",
      name: name,
      file_deleted: deleted_file?
    )

    content =
      if deleted_file? do
        "Workflow '#{name}' canceled and file deleted."
      else
        "Workflow '#{name}' cron job removed. File preserved at #{path}."
      end

    {:ok,
     %Result{
       status: :ok,
       content: content,
       side_effects: [:workflow_canceled],
       metadata: %{workflow_name: name, file_deleted: deleted_file?}
     }}
  end

  defp delete_flag?(flags) do
    case Map.get(flags, "delete") do
      nil -> false
      "false" -> false
      _ -> true
    end
  end

  defp delete_file(path) do
    case File.rm(path) do
      :ok ->
        true

      {:error, reason} ->
        Logger.warning("workflow.cancel: failed to delete file",
          path: path,
          reason: inspect(reason)
        )

        false
    end
  end

  defp valid_workflow_name?(name) do
    Regex.match?(~r/^[a-z][a-z0-9_-]*$/, name)
  end

  defp workflow_path(name) do
    dir = Helpers.resolve_workflows_dir()
    Path.join(dir, "#{name}.md")
  end
end
