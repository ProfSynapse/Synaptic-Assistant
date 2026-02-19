# lib/assistant/scheduler/workers/compaction_worker.ex — Oban worker for conversation compaction.
#
# Wraps Memory.Compaction.compact/2 for reliable async execution. Enqueued by
# ContextMonitor or TurnClassifier when token utilization crosses the compaction
# threshold or a topic change is detected.
#
# Uses Oban's unique job feature to prevent concurrent compaction of the same
# conversation: only one compaction job per conversation_id can be active within
# a 60-second window.
#
# Related files:
#   - lib/assistant/memory/compaction.ex (core compaction logic)
#   - lib/assistant/memory/context_monitor.ex (triggers compaction on utilization threshold)
#   - lib/assistant/memory/turn_classifier.ex (triggers compaction on topic change)
#   - config/config.exs (Oban queue config: compaction queue with 5 workers)

defmodule Assistant.Scheduler.Workers.CompactionWorker do
  @moduledoc """
  Oban worker that runs conversation compaction asynchronously.

  ## Queue

  Runs in the `:compaction` queue (configured with 5 concurrent workers in
  `config/config.exs`).

  ## Uniqueness

  Uses `unique: [fields: [:args], keys: [:conversation_id], period: 60]` to
  ensure at most one compaction job per conversation is active within a 60-second
  window. This prevents duplicate compaction when both ContextMonitor and
  TurnClassifier fire for the same conversation in quick succession.

  ## Retry Policy

  Max 3 attempts with Oban's default exponential backoff. Compaction failures
  are typically transient (LLM rate limiting, network timeouts).

  ## Enqueuing

      %{conversation_id: conv_id}
      |> CompactionWorker.new()
      |> Oban.insert()
  """

  use Oban.Worker,
    queue: :compaction,
    max_attempts: 3,
    unique: [fields: [:args], keys: [:conversation_id], period: 60]

  require Logger

  alias Assistant.Memory.Compaction

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    conversation_id = args["conversation_id"]

    unless conversation_id do
      Logger.error("CompactionWorker: missing conversation_id in args", args: inspect(args))
      {:error, :missing_conversation_id}
    else
      Logger.info("CompactionWorker: starting compaction", conversation_id: conversation_id)

      opts = build_opts(args)

      case Compaction.compact(conversation_id, opts) do
        {:ok, conversation} ->
          Logger.info("CompactionWorker: compaction succeeded",
            conversation_id: conversation_id,
            summary_version: conversation.summary_version
          )

          :ok

        {:error, :no_new_messages} ->
          Logger.info("CompactionWorker: no new messages to compact",
            conversation_id: conversation_id
          )

          :ok

        {:error, :not_found} ->
          Logger.warning("CompactionWorker: conversation not found",
            conversation_id: conversation_id
          )

          # Don't retry for missing conversations
          {:cancel, :conversation_not_found}

        {:error, :no_compaction_model} ->
          Logger.error("CompactionWorker: no compaction model configured")
          # Don't retry for missing config
          {:cancel, :no_compaction_model}

        {:error, reason} ->
          Logger.error("CompactionWorker: compaction failed",
            conversation_id: conversation_id,
            reason: inspect(reason)
          )

          {:error, reason}
      end
    end
  end

  defp build_opts(args) do
    opts = []

    opts =
      case args["token_budget"] do
        nil -> opts
        budget when is_integer(budget) -> Keyword.put(opts, :token_budget, budget)
        _ -> opts
      end

    case args["message_limit"] do
      nil -> opts
      limit when is_integer(limit) -> Keyword.put(opts, :message_limit, limit)
      _ -> opts
    end
  end
end
