# lib/assistant/workers/pending_intent_worker.ex — Oban worker for replaying user intent post-OAuth.
#
# When a user invokes a Google-dependent skill without a connected account,
# the orchestrator generates a magic link and parks a PendingIntentWorker Oban
# job at a far-future scheduled_at. After the user completes OAuth, the
# OAuthController reschedules this job to run immediately.
#
# The worker replays the original user message through the full orchestrator
# pipeline (ensuring rate limiting, sentinel, and skill validation all apply).
# It then delivers the response via the appropriate channel adapter.
#
# Related files:
#   - lib/assistant_web/controllers/oauth_controller.ex (reschedules this worker)
#   - lib/assistant/auth/magic_link.ex (generate/2 creates the parked job)
#   - lib/assistant/orchestrator/engine.ex (processes the replayed message)
#   - lib/assistant/channels/adapter.ex (channel delivery behaviour)
#   - lib/assistant/channels/google_chat.ex (Google Chat delivery)

defmodule Assistant.Workers.PendingIntentWorker do
  @moduledoc """
  Oban worker that replays a user's original command after OAuth authorization.

  ## Lifecycle

    1. **Parked**: Inserted with `scheduled_at` far in the future when magic link
       is generated. The job sits in `:scheduled` state until OAuth completes.
    2. **Rescheduled**: `OAuthController.callback/2` updates `scheduled_at` to
       `DateTime.utc_now()` after tokens are stored.
    3. **Executed**: Oban picks up the job. Worker validates TTL, ensures the
       conversation engine is running, replays the message, and delivers the
       response via the original channel.

  ## Queue

  Runs in the `:oauth_replay` queue.

  ## Uniqueness

  One pending intent per user. If a new magic link is generated for the same
  user, the old parked job is superseded (magic link latest-wins policy
  invalidates the old auth_token, so the old job's oban_job_id becomes stale).

  ## TTL

  Jobs older than 10 minutes (from `inserted_at`) are discarded as stale.

  ## Enqueuing

      %{
        user_id: "uuid",
        conversation_id: "gchat:spaces/xxx",
        original_message: "What's on my calendar?",
        channel: "google_chat",
        reply_context: %{"space_id" => "spaces/xxx", "thread_id" => "spaces/xxx/threads/yyy"}
      }
      |> PendingIntentWorker.new(scheduled_at: ~U[2099-01-01 00:00:00Z])
      |> Oban.insert()
  """

  use Oban.Worker,
    queue: :oauth_replay,
    max_attempts: 3,
    unique: [fields: [:args], keys: [:user_id], period: :infinity, states: [:scheduled]]

  require Logger

  alias Assistant.Orchestrator.Engine

  @intent_ttl_seconds 10 * 60

  @impl Oban.Worker
  def perform(%Oban.Job{args: args, inserted_at: inserted_at}) do
    user_id = args["user_id"]
    conversation_id = args["conversation_id"]
    original_message = args["original_message"]
    channel = args["channel"]
    reply_context = args["reply_context"] || %{}

    unless user_id && conversation_id && original_message && channel do
      Logger.error("PendingIntentWorker: missing required args",
        args: inspect(Map.keys(args))
      )

      {:cancel, :missing_args}
    else
      if intent_stale?(inserted_at) do
        Logger.info("PendingIntentWorker: intent too stale, discarding",
          user_id: user_id,
          conversation_id: conversation_id,
          age_seconds: DateTime.diff(DateTime.utc_now(), inserted_at)
        )

        {:cancel, :intent_expired}
      else
        replay_intent(user_id, conversation_id, original_message, channel, reply_context)
      end
    end
  end

  # --- Private ---

  defp intent_stale?(nil), do: false
  defp intent_stale?(inserted_at) do
    age = DateTime.diff(DateTime.utc_now(), inserted_at)
    age > @intent_ttl_seconds
  end

  defp replay_intent(user_id, conversation_id, original_message, channel, reply_context) do
    Logger.info("PendingIntentWorker: replaying intent",
      user_id: user_id,
      conversation_id: conversation_id,
      channel: channel,
      message_preview: String.slice(original_message, 0, 50)
    )

    with :ok <- ensure_engine_started(conversation_id, user_id, channel),
         {:ok, response_text} <- Engine.send_message(conversation_id, original_message) do
      deliver_response(channel, response_text, reply_context)

      Logger.info("PendingIntentWorker: intent replayed successfully",
        user_id: user_id,
        conversation_id: conversation_id
      )

      :ok
    else
      {:error, reason} ->
        Logger.error("PendingIntentWorker: replay failed",
          user_id: user_id,
          conversation_id: conversation_id,
          reason: inspect(reason)
        )

        {:error, reason}
    end
  end

  # Start the orchestrator engine for this conversation if not already running.
  # Follows the pattern from GoogleChatController.ensure_engine_started/2.
  defp ensure_engine_started(conversation_id, user_id, channel) do
    case Engine.get_state(conversation_id) do
      {:ok, _state} ->
        :ok

      {:error, :not_found} ->
        opts = [
          user_id: user_id,
          channel: channel,
          mode: :multi_agent
        ]

        child_spec = %{
          id: conversation_id,
          start: {Engine, :start_link, [conversation_id, opts]},
          restart: :temporary
        }

        case DynamicSupervisor.start_child(
               Assistant.Orchestrator.ConversationSupervisor,
               child_spec
             ) do
          {:ok, _pid} ->
            Logger.info("PendingIntentWorker: started conversation engine",
              conversation_id: conversation_id,
              user_id: user_id
            )

            :ok

          {:error, {:already_started, _pid}} ->
            :ok

          {:error, reason} ->
            Logger.error("PendingIntentWorker: failed to start engine",
              conversation_id: conversation_id,
              reason: inspect(reason)
            )

            {:error, reason}
        end
    end
  end

  # Deliver the response via the appropriate channel adapter.
  defp deliver_response("google_chat", text, reply_context) do
    space_id = reply_context["space_id"]

    unless space_id do
      Logger.warning("PendingIntentWorker: missing space_id in reply_context for google_chat")
      :ok
    else
      opts =
        case reply_context["thread_id"] do
          nil -> []
          thread_id -> [thread_name: thread_id]
        end

      case Assistant.Channels.GoogleChat.send_reply(space_id, text, opts) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.error("PendingIntentWorker: failed to deliver response via google_chat",
            space_id: space_id,
            reason: inspect(reason)
          )

          :ok
      end
    end
  end

  # Fallback for other channels — log and move on.
  # Additional channel adapters can be added here as they are implemented.
  defp deliver_response(channel, _text, _reply_context) do
    Logger.warning("PendingIntentWorker: unsupported channel for delivery",
      channel: channel
    )

    :ok
  end
end
