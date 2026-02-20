# lib/assistant/scheduler/workers/memory_save_worker.ex — Oban worker for async memory save
# after sub-agent completion.
#
# Enqueued by the orchestrator Engine after a sub-agent finishes its mission.
# Saves the full agent transcript (tool calls, results, reasoning) to the
# memory store so the system can recall what was done in prior turns.
#
# Non-blocking by design: the engine enqueues and moves on. Memory save
# failures are logged but never surface to the user or affect the response.
#
# Related files:
#   - lib/assistant/orchestrator/engine.ex (enqueues after agent completion,
#     serializes transcript via serialize_transcript/1)
#   - lib/assistant/memory/store.ex (create_memory_entry/1)
#   - lib/assistant/scheduler/workers/compaction_worker.ex (sibling Oban worker pattern)
#   - config/config.exs (Oban queue config: memory queue)

defmodule Assistant.Scheduler.Workers.MemorySaveWorker do
  @moduledoc """
  Oban worker that saves the full sub-agent transcript to long-term memory.

  The transcript includes the agent's tool calls, skill results, and reasoning
  — everything the sub-agent produced during execution. The Engine serializes
  the transcript before enqueuing; this worker persists it to the memory store.

  ## Queue

  Runs in the `:memory` queue (configured with 5 concurrent workers in
  `config/config.exs`).

  ## Uniqueness

  Uses `unique: [fields: [:args], keys: [:agent_id, :conversation_id], period: 30]`
  to prevent duplicate saves if the same agent result is enqueued more than once
  within a 30-second window.

  ## Retry Policy

  Max 2 attempts. Memory save failures are non-critical — a failed save
  should not block the user's response or cause noise. If both attempts fail,
  the job is discarded silently.

  ## Enqueuing

      %{
        user_id: user_id,
        conversation_id: conversation_id,
        agent_id: agent_id,
        mission: mission_text,
        transcript: serialized_transcript,
        status: "completed"
      }
      |> MemorySaveWorker.new()
      |> Oban.insert()
  """

  use Oban.Worker,
    queue: :memory,
    max_attempts: 2,
    unique: [fields: [:args], keys: [:agent_id, :conversation_id], period: 30]

  require Logger

  alias Assistant.Memory.Store

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    user_id = args["user_id"]
    conversation_id = args["conversation_id"]
    agent_id = args["agent_id"]
    mission = args["mission"]
    transcript = args["transcript"]
    status = args["status"] || "completed"

    unless user_id && conversation_id && agent_id do
      Logger.warning("MemorySaveWorker: missing required args, skipping",
        user_id: user_id,
        conversation_id: conversation_id,
        agent_id: agent_id
      )

      # Cancel — don't retry for bad args
      {:cancel, :missing_required_args}
    else
      content = build_content(agent_id, mission, transcript, status)

      attrs = %{
        content: content,
        user_id: user_id,
        source_conversation_id: conversation_id,
        source_type: "agent_result",
        tags: build_tags(agent_id, status),
        category: "agent_transcript"
      }

      case Store.create_memory_entry(attrs) do
        {:ok, entry} ->
          Logger.info("MemorySaveWorker: saved agent transcript",
            entry_id: entry.id,
            agent_id: agent_id,
            conversation_id: conversation_id
          )

          :ok

        {:error, changeset} ->
          Logger.warning("MemorySaveWorker: failed to save agent transcript",
            agent_id: agent_id,
            conversation_id: conversation_id,
            errors: inspect(changeset.errors)
          )

          # Return :ok to not retry on changeset validation errors — they won't
          # succeed on retry either.
          :ok
      end
    end
  end

  defp build_content(agent_id, mission, transcript, status) do
    header = "Agent: #{agent_id}\nStatus: #{status}"

    mission_section =
      case mission do
        nil -> ""
        "" -> ""
        text -> "\n\nMission: #{text}"
      end

    transcript_section =
      case transcript do
        nil -> "\n\n(no transcript)"
        "" -> "\n\n(empty transcript)"
        text -> "\n\nTranscript:\n#{text}"
      end

    header <> mission_section <> transcript_section
  end

  defp build_tags(agent_id, status) do
    ["agent:#{agent_id}", "status:#{status}"]
  end
end
