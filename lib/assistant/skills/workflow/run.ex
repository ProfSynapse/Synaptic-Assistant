# lib/assistant/skills/workflow/run.ex — Handler for workflow.run skill.
#
# Runs a workflow immediately by enqueuing an Oban WorkflowWorker job.
# Bypasses the cron schedule — useful for testing or one-off execution.
#
# Related files:
#   - lib/assistant/scheduler/workflow_worker.ex (the Oban worker)
#   - priv/skills/workflow/run.md (skill definition)

defmodule Assistant.Skills.Workflow.Run do
  @moduledoc """
  Skill handler for running a workflow immediately.

  Enqueues an Oban `WorkflowWorker` job for the named workflow,
  bypassing its cron schedule.
  """

  @behaviour Assistant.Skills.Handler

  require Logger

  alias Assistant.Scheduler.WorkflowWorker
  alias Assistant.Skills.Result

  @workflows_dir Application.compile_env(
                   :assistant,
                   :workflows_dir,
                   "priv/workflows"
                 )

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
      path = workflow_path(name)

      if File.exists?(path) do
        enqueue_workflow(name, path)
      else
        {:ok,
         %Result{
           status: :error,
           content: "Workflow '#{name}' not found. Use `/workflow.list` to see available workflows."
         }}
      end
    end
  end

  # --- Private ---

  defp enqueue_workflow(name, path) do
    relative_path = Path.relative_to_cwd(path)

    case %{workflow_path: relative_path} |> WorkflowWorker.new() |> Oban.insert() do
      {:ok, job} ->
        Logger.info("workflow.run: enqueued workflow", name: name, job_id: job.id)

        {:ok,
         %Result{
           status: :ok,
           content: "Workflow '#{name}' enqueued for immediate execution (job ##{job.id}).",
           metadata: %{job_id: job.id, workflow_name: name}
         }}

      {:error, reason} ->
        Logger.error("workflow.run: failed to enqueue", name: name, reason: inspect(reason))

        {:ok,
         %Result{
           status: :error,
           content: "Failed to enqueue workflow '#{name}': #{inspect(reason)}"
         }}
    end
  end

  defp workflow_path(name) do
    dir = resolve_workflows_dir()
    Path.join(dir, "#{name}.md")
  end

  defp resolve_workflows_dir do
    case Application.get_env(:assistant, :workflows_dir) do
      nil -> Path.join(Application.app_dir(:assistant), @workflows_dir)
      dir -> dir
    end
  end
end
