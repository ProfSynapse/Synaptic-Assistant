# lib/assistant/scheduler/workflow_worker.ex — Oban worker for scheduled workflows.
#
# Loads a workflow prompt file from priv/workflows/, parses its YAML frontmatter
# and markdown body, runs the prompt through the agent, and optionally posts
# the result to a Google Chat space if the `channel` field is set.
#
# Enqueued by QuantumLoader on cron schedule, or directly by the workflow.run
# skill for immediate execution.
#
# Related files:
#   - lib/assistant/scheduler/quantum_loader.ex (registers cron jobs that enqueue this worker)
#   - lib/assistant/skills/workflow/run.ex (immediate execution skill)
#   - lib/assistant/integrations/google/chat.ex (Chat posting for channel delivery)
#   - lib/assistant/skills/loader.ex (frontmatter parsing)

defmodule Assistant.Scheduler.WorkflowWorker do
  @moduledoc """
  Oban worker that executes workflow prompt files.

  ## Queue

  Runs in the `:scheduled` queue (configured with 5 concurrent workers).

  ## Uniqueness

  Uses `unique: [fields: [:args], keys: [:workflow_path], period: 300]` to
  prevent duplicate runs of the same workflow within a 5-minute window.

  ## Args

    * `"workflow_path"` - Absolute or relative path to the workflow .md file

  ## Enqueuing

      %{workflow_path: "priv/workflows/morning-digest.md"}
      |> WorkflowWorker.new()
      |> Oban.insert()
  """

  use Oban.Worker,
    queue: :scheduled,
    max_attempts: 3,
    unique: [fields: [:args], keys: [:workflow_path], period: 300]

  require Logger

  alias Assistant.Skills.Loader

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"workflow_path" => path}}) do
    Logger.info("WorkflowWorker: starting workflow", path: path)

    with {:ok, content} <- read_workflow(path),
         {:ok, frontmatter, body} <- Loader.parse_frontmatter(content) do
      name = frontmatter["name"] || Path.basename(path, ".md")
      prompt = String.trim(body)

      # TODO: Replace with actual agent execution when Assistant.Orchestrator
      # exposes a run_prompt/2 or similar API. For now, log the prompt.
      Logger.info("WorkflowWorker: running workflow",
        name: name,
        prompt_length: String.length(prompt)
      )

      result = execute_prompt(name, prompt)

      maybe_post_to_channel(frontmatter["channel"], name, result)

      Logger.info("WorkflowWorker: workflow completed", name: name)
      :ok
    else
      {:error, reason} ->
        Logger.error("WorkflowWorker: failed",
          path: path,
          reason: inspect(reason)
        )

        {:error, reason}
    end
  end

  def perform(%Oban.Job{args: args}) do
    Logger.error("WorkflowWorker: missing workflow_path in args", args: inspect(args))
    {:error, :missing_workflow_path}
  end

  # --- Private ---

  defp read_workflow(path) do
    abs_path = resolve_path(path)

    case File.read(abs_path) do
      {:ok, _content} = ok -> ok
      {:error, :enoent} -> {:error, {:workflow_not_found, path}}
      {:error, reason} -> {:error, {:read_error, reason}}
    end
  end

  defp resolve_path(path) do
    if Path.type(path) == :absolute do
      path
    else
      Path.join(Application.app_dir(:assistant), path)
    end
  end

  # Stub: runs the prompt through the agent.
  # TODO: Wire to Assistant.Orchestrator.Engine or equivalent when the
  # agent execution API is finalized. The expected contract is:
  #   Agent.run(prompt) :: {:ok, response_text} | {:error, reason}
  defp execute_prompt(name, prompt) do
    Logger.info("WorkflowWorker: executing prompt (stubbed)",
      workflow: name,
      prompt_preview: String.slice(prompt, 0, 100)
    )

    "[Workflow #{name}] Execution stubbed — prompt has #{String.length(prompt)} characters."
  end

  defp maybe_post_to_channel(nil, _name, _result), do: :ok

  defp maybe_post_to_channel(channel, name, result) do
    text = "**Workflow: #{name}**\n\n#{result}"

    case Assistant.Integrations.Google.Chat.send_message(channel, text) do
      {:ok, _resp} ->
        Logger.info("WorkflowWorker: posted result to channel",
          workflow: name,
          channel: channel
        )

      {:error, reason} ->
        Logger.warning("WorkflowWorker: failed to post to channel",
          workflow: name,
          channel: channel,
          reason: inspect(reason)
        )
    end
  end
end
