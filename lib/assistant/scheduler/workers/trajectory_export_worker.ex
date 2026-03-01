# lib/assistant/scheduler/workers/trajectory_export_worker.ex — Oban worker
# for async JSONL trajectory export after each conversation turn.
#
# Enqueued by the Engine after each turn completes. Writes the full turn
# trace (messages, tool calls, sub-agent results, usage) as a JSONL line
# for future fine-tuning and analysis.
#
# Non-blocking: the engine fires and forgets. Export failures are logged
# but never surface to the user.
#
# Related files:
#   - lib/assistant/analytics/trajectory_exporter.ex (writes JSONL)
#   - lib/assistant/analytics/trajectory_format.ex (formats data)
#   - lib/assistant/orchestrator/engine.ex (enqueues after turn completion)

defmodule Assistant.Scheduler.Workers.TrajectoryExportWorker do
  @moduledoc """
  Oban worker that exports a conversation turn as a JSONL trajectory line.

  ## Queue

  Runs in the `:default` queue. Trajectory export is low-priority —
  it should not compete with memory saves or email delivery.

  ## Retry Policy

  Max 1 attempt. Trajectory export is best-effort. If it fails, we lose
  one turn's data but the system continues normally.
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 1

  require Logger

  alias Assistant.Analytics.TrajectoryExporter

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    # Convert string keys back to atoms for the exporter
    attrs = %{
      conversation_id: args["conversation_id"],
      user_id: args["user_id"],
      user_message: args["user_message"],
      assistant_response: args["assistant_response"],
      messages: args["messages"] || [],
      dispatched_agents: atomize_agents(args["dispatched_agents"]),
      usage: atomize_usage(args["usage"]),
      model: args["model"],
      mode: args["mode"],
      channel: args["channel"],
      iteration_count: args["iteration_count"]
    }

    TrajectoryExporter.export_turn(attrs)
    :ok
  end

  defp atomize_agents(nil), do: %{}

  defp atomize_agents(agents) when is_map(agents) do
    Map.new(agents, fn {k, v} ->
      {k,
       %{
         status: v["status"],
         result: v["result"],
         tool_calls_used: v["tool_calls_used"],
         duration_ms: v["duration_ms"]
       }}
    end)
  end

  defp atomize_agents(_), do: %{}

  defp atomize_usage(nil), do: %{}

  defp atomize_usage(usage) when is_map(usage) do
    %{
      prompt_tokens: usage["prompt_tokens"] || 0,
      completion_tokens: usage["completion_tokens"] || 0
    }
  end

  defp atomize_usage(_), do: %{}
end
