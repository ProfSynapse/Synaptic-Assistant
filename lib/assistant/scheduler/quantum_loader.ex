# lib/assistant/scheduler/quantum_loader.ex — GenServer that loads cron workflows.
#
# On init, scans priv/workflows/*.md for files with a `cron:` frontmatter field.
# For each, registers a Quantum job that enqueues a WorkflowWorker via Oban on
# the cron schedule. This bridges Quantum (cron timing) with Oban (reliable execution).
#
# Job names use `make_ref()` (not atoms) to avoid unbounded atom creation from
# user-controlled workflow names. The ref-to-name mapping is tracked in GenServer
# state so jobs can be removed on reload.
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

  @doc """
  Cancel a specific workflow's cron job by workflow name.

  Removes the Quantum job and forgets the ref. Returns `:ok` regardless
  of whether the workflow was scheduled (idempotent).
  """
  @spec cancel(String.t()) :: :ok
  def cancel(workflow_name) do
    GenServer.call(__MODULE__, {:cancel, workflow_name})
  end

  # --- Server Callbacks ---

  @impl true
  def init(_opts) do
    {count, job_refs} = load_workflows()
    Logger.info("QuantumLoader: initialized", scheduled_workflows: count)
    {:ok, %{scheduled_count: count, job_refs: job_refs}}
  end

  @impl true
  def handle_call(:reload, _from, state) do
    remove_workflow_jobs(state.job_refs)
    {count, job_refs} = load_workflows()
    Logger.info("QuantumLoader: reloaded", scheduled_workflows: count)
    {:reply, :ok, %{scheduled_count: count, job_refs: job_refs}}
  end

  @impl true
  def handle_call({:cancel, workflow_name}, _from, state) do
    case Map.pop(state.job_refs, workflow_name) do
      {nil, _refs} ->
        {:reply, :ok, state}

      {ref, remaining_refs} ->
        Assistant.Scheduler.delete_job(ref)
        Logger.info("QuantumLoader: canceled workflow job", workflow: workflow_name)
        {:reply, :ok, %{state | job_refs: remaining_refs, scheduled_count: map_size(remaining_refs)}}
    end
  end

  # --- Private ---

  defp load_workflows do
    workflows_path = resolve_workflows_dir()

    case File.ls(workflows_path) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, ".md"))
        |> Enum.reject(&(&1 == ".gitkeep"))
        |> Enum.reduce({0, %{}}, fn filename, {count, refs} ->
          path = Path.join(workflows_path, filename)

          case register_if_scheduled(path) do
            {:ok, workflow_name, ref} -> {count + 1, Map.put(refs, workflow_name, ref)}
            :skip -> {count, refs}
          end
        end)

      {:error, reason} ->
        Logger.warning("QuantumLoader: cannot read workflows directory",
          path: workflows_path,
          reason: inspect(reason)
        )

        {0, %{}}
    end
  end

  defp register_if_scheduled(path) do
    with {:ok, content} <- File.read(path),
         {:ok, frontmatter, _body} <- Loader.parse_frontmatter(content),
         cron when is_binary(cron) <- frontmatter["cron"] do
      name = frontmatter["name"] || Path.basename(path, ".md")

      case Crontab.CronExpression.Parser.parse(cron) do
        {:ok, _expression} ->
          ref = make_ref()
          job = build_quantum_job(ref, cron, path)
          Assistant.Scheduler.add_job(job)

          Logger.info("QuantumLoader: registered cron job",
            workflow: name,
            cron: cron,
            job_ref: inspect(ref)
          )

          {:ok, name, ref}

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

  defp build_quantum_job(job_ref, cron, workflow_path) do
    # Relative path for portability in Oban args
    relative_path = Path.relative_to_cwd(workflow_path)

    Assistant.Scheduler.new_job()
    |> Quantum.Job.set_name(job_ref)
    |> Quantum.Job.set_schedule(Crontab.CronExpression.Parser.parse!(cron))
    |> Quantum.Job.set_task(fn ->
      %{workflow_path: relative_path}
      |> Assistant.Scheduler.WorkflowWorker.new()
      |> Oban.insert()
    end)
  end

  defp remove_workflow_jobs(job_refs) do
    Enum.each(job_refs, fn {_name, ref} ->
      Assistant.Scheduler.delete_job(ref)
    end)
  end

  defp resolve_workflows_dir do
    case Application.get_env(:assistant, :workflows_dir) do
      nil -> Path.join(Application.app_dir(:assistant), @workflows_dir)
      dir -> dir
    end
  end
end
