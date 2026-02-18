# lib/assistant/scheduler/quantum_loader.ex — GenServer that loads cron workflows.
#
# On init, scans priv/workflows/*.md for files with a `cron:` frontmatter field.
# For each, registers a Quantum job that enqueues a WorkflowWorker via Oban on
# the cron schedule. This bridges Quantum (cron timing) with Oban (reliable execution).
#
# Related files:
#   - lib/assistant/scheduler/workflow_worker.ex (the Oban worker enqueued by jobs)
#   - lib/assistant/skills/loader.ex (frontmatter parsing)
#   - lib/assistant/application.ex (supervision tree — starts after Assistant.Scheduler)

defmodule Assistant.Scheduler.QuantumLoader do
  @moduledoc """
  GenServer that scans workflow files and registers Quantum cron jobs.

  On startup, reads all `priv/workflows/*.md` files, parses YAML frontmatter,
  and for any file with a `cron:` field, adds a Quantum job to
  `Assistant.Scheduler`. Each job enqueues an Oban `WorkflowWorker` at the
  specified schedule.

  ## Supervision

  Should start after `Assistant.Scheduler` and `Oban` in the supervision tree.
  """

  use GenServer

  require Logger

  alias Assistant.Skills.Loader

  @workflows_dir "priv/workflows"

  # --- Client API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Reload all workflow cron jobs. Removes existing workflow jobs and re-scans
  the workflows directory. Useful after creating or deleting workflow files.
  """
  @spec reload() :: :ok
  def reload do
    GenServer.call(__MODULE__, :reload)
  end

  # --- Server Callbacks ---

  @impl true
  def init(_opts) do
    schedule_count = load_workflows()
    Logger.info("QuantumLoader: initialized", scheduled_workflows: schedule_count)
    {:ok, %{scheduled_count: schedule_count}}
  end

  @impl true
  def handle_call(:reload, _from, _state) do
    remove_workflow_jobs()
    count = load_workflows()
    Logger.info("QuantumLoader: reloaded", scheduled_workflows: count)
    {:reply, :ok, %{scheduled_count: count}}
  end

  # --- Private ---

  defp load_workflows do
    workflows_path = resolve_workflows_dir()

    case File.ls(workflows_path) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, ".md"))
        |> Enum.reject(&(&1 == ".gitkeep"))
        |> Enum.reduce(0, fn filename, count ->
          path = Path.join(workflows_path, filename)
          case register_if_scheduled(path) do
            :ok -> count + 1
            :skip -> count
          end
        end)

      {:error, reason} ->
        Logger.warning("QuantumLoader: cannot read workflows directory",
          path: workflows_path,
          reason: inspect(reason)
        )

        0
    end
  end

  defp register_if_scheduled(path) do
    with {:ok, content} <- File.read(path),
         {:ok, frontmatter, _body} <- Loader.parse_frontmatter(content),
         cron when is_binary(cron) <- frontmatter["cron"] do
      name = frontmatter["name"] || Path.basename(path, ".md")
      job_name = workflow_job_name(name)

      case Crontab.CronExpression.Parser.parse(cron) do
        {:ok, _expression} ->
          job = build_quantum_job(job_name, cron, path)
          Assistant.Scheduler.add_job(job)

          Logger.info("QuantumLoader: registered cron job",
            workflow: name,
            cron: cron,
            job_name: inspect(job_name)
          )

          :ok

        {:error, reason} ->
          Logger.warning("QuantumLoader: invalid cron expression",
            workflow: name,
            cron: cron,
            reason: inspect(reason)
          )

          :skip
      end
    else
      nil -> :skip
      {:error, _} -> :skip
    end
  end

  defp build_quantum_job(job_name, cron, workflow_path) do
    # Relative path for portability in Oban args
    relative_path = Path.relative_to_cwd(workflow_path)

    Assistant.Scheduler.new_job()
    |> Quantum.Job.set_name(job_name)
    |> Quantum.Job.set_schedule(Crontab.CronExpression.Parser.parse!(cron))
    |> Quantum.Job.set_task(fn ->
      %{workflow_path: relative_path}
      |> Assistant.Scheduler.WorkflowWorker.new()
      |> Oban.insert()
    end)
  end

  defp remove_workflow_jobs do
    Assistant.Scheduler.jobs()
    |> Enum.each(fn {name, _job} ->
      if is_atom(name) and String.starts_with?(Atom.to_string(name), "workflow_") do
        Assistant.Scheduler.delete_job(name)
      end
    end)
  end

  defp workflow_job_name(name) do
    safe_name =
      name
      |> String.replace(~r/[^a-zA-Z0-9_-]/, "_")
      |> String.downcase()

    String.to_atom("workflow_#{safe_name}")
  end

  defp resolve_workflows_dir do
    case Application.get_env(:assistant, :workflows_dir) do
      nil -> Path.join(Application.app_dir(:assistant), @workflows_dir)
      dir -> dir
    end
  end
end
