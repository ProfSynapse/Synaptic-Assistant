# lib/assistant/skills/memory/compact_conversation.ex — Handler for memory.compact_conversation skill.
#
# Enqueues a CompactionWorker Oban job for the specified conversation.
# The actual compaction logic (LLM summarization, summary update) runs
# asynchronously via the Oban worker.
#
# Related files:
#   - lib/assistant/scheduler/workers/compaction_worker.ex (Oban worker)
#   - lib/assistant/memory/compaction.ex (core compaction logic)
#   - priv/skills/memory/compact_conversation.md (skill definition)

defmodule Assistant.Skills.Memory.CompactConversation do
  @moduledoc """
  Handler for the `memory.compact_conversation` skill.

  Enqueues a `CompactionWorker` Oban job for the given conversation.
  The worker handles deduplication (unique per conversation_id within
  60 seconds) and retry logic (max 3 attempts).

  This is a fire-and-forget operation -- the compaction runs
  asynchronously. The handler returns immediately with confirmation
  that the job was enqueued.
  """

  @behaviour Assistant.Skills.Handler

  alias Assistant.Memory.Store
  alias Assistant.Scheduler.Workers.CompactionWorker
  alias Assistant.Skills.Result

  require Logger

  @impl true
  def execute(flags, context) do
    conversation_id = flags["conversation_id"] || flags["id"]

    unless conversation_id && conversation_id != "" do
      {:ok,
       %Result{
         status: :error,
         content: "Missing required parameter: conversation_id"
       }}
    else
      with {:ok, conv} <- Store.get_conversation(conversation_id),
           true <- conv.user_id == context.user_id do
        args = build_args(conversation_id, flags)

        case CompactionWorker.new(args) |> Oban.insert() do
          {:ok, job} ->
            Logger.info("Compaction enqueued",
              conversation_id: conversation_id,
              job_id: job.id
            )

            {:ok,
             %Result{
               status: :ok,
               content:
                 Jason.encode!(%{
                   status: "enqueued",
                   conversation_id: conversation_id,
                   job_id: job.id
                 }),
               side_effects: [:compaction_enqueued],
               metadata: %{job_id: job.id, conversation_id: conversation_id}
             }}

          {:error, reason} ->
            Logger.error("Failed to enqueue compaction",
              conversation_id: conversation_id,
              reason: inspect(reason)
            )

            {:ok,
             %Result{
               status: :error,
               content: "Failed to enqueue compaction: #{inspect(reason)}"
             }}
        end
      else
        _not_owned_or_not_found ->
          {:ok,
           %Result{
             status: :error,
             content: "Conversation not found: #{conversation_id}"
           }}
      end
    end
  end

  defp build_args(conversation_id, flags) do
    args = %{conversation_id: conversation_id}

    args =
      case flags["token_budget"] do
        nil -> args
        budget -> Map.put(args, :token_budget, parse_int(budget))
      end

    case flags["message_limit"] do
      nil -> args
      limit -> Map.put(args, :message_limit, parse_int(limit))
    end
  end

  defp parse_int(val) when is_integer(val), do: val

  defp parse_int(val) when is_binary(val) do
    case Integer.parse(val) do
      {i, _} -> i
      :error -> nil
    end
  end

  defp parse_int(_), do: nil
end
