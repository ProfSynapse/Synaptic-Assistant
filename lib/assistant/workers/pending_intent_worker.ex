# lib/assistant/workers/pending_intent_worker.ex — Oban worker for replaying
# user commands after OAuth authorization completes.
#
# When a user invokes a Google-dependent skill without a connected account,
# a magic link is generated and this worker is enqueued with the original
# command. After the user completes OAuth, the OAuthController reschedules
# this job to run immediately. The worker replays the original message
# through the full orchestrator pipeline (rate limiting, sentinel, skills).
#
# Related files:
#   - lib/assistant/auth/magic_link.ex (enqueues this worker during generate/3)
#   - lib/assistant_web/controllers/oauth_controller.ex (reschedules on callback)
#   - lib/assistant/orchestrator/engine.ex (message processing entry point)
#   - lib/assistant/channels/google_chat.ex (channel adapter for replies)
#   - config/config.exs (Oban queue config: oauth_replay queue)

defmodule Assistant.Workers.PendingIntentWorker do
  @moduledoc """
  Oban worker that replays a user's original command after OAuth authorization.

  ## Queue

  Runs in the `:oauth_replay` queue (configured with 5 concurrent workers
  in `config/config.exs`).

  ## Lifecycle

  1. Magic link generation enqueues this job with the user's original message,
     conversation_id, channel, and reply_context.
  2. The job is initially inserted as a normal job — it runs when picked up.
  3. After OAuth callback stores the user's tokens, the controller may
     reschedule this job if needed.
  4. On execution, the worker checks staleness (10-minute TTL from insertion),
     starts or finds the conversation engine, sends the message through the
     full orchestrator pipeline, and delivers the response via the channel.

  ## Staleness

  Jobs older than 10 minutes from `inserted_at` are discarded. The user's
  intent is likely stale by then, and replaying old commands could be
  confusing.

  ## Uniqueness

  Uses `unique: [fields: [:args], period: :infinity, states: [:scheduled]]`
  to prevent duplicate replay jobs for the same user intent.
  """

  use Oban.Worker,
    queue: :oauth_replay,
    max_attempts: 2,
    unique: [fields: [:args], keys: [:user_id], period: 300, states: [:available, :scheduled]]

  alias Assistant.Orchestrator.Engine

  require Logger

  @staleness_seconds 600

  @impl Oban.Worker
  def perform(%Oban.Job{args: args, inserted_at: inserted_at}) do
    user_id = args["user_id"]
    message = args["message"]
    conversation_id = args["conversation_id"]
    channel = args["channel"]
    reply_context = args["reply_context"] || %{}

    unless user_id && message && conversation_id do
      Logger.error("PendingIntentWorker: missing required args",
        args: inspect(Map.take(args, ["user_id", "conversation_id"]))
      )

      {:cancel, :missing_required_args}
    else
      if stale?(inserted_at) do
        Logger.info("PendingIntentWorker: discarding stale intent",
          user_id: user_id,
          conversation_id: conversation_id,
          inserted_at: inspect(inserted_at)
        )

        {:cancel, :stale_intent}
      else
        replay_message(user_id, message, conversation_id, channel, reply_context)
      end
    end
  end

  # --- Private ---

  defp stale?(inserted_at) do
    age_seconds = DateTime.diff(DateTime.utc_now(), inserted_at, :second)
    age_seconds > @staleness_seconds
  end

  defp replay_message(user_id, message, conversation_id, channel, reply_context) do
    Logger.info("PendingIntentWorker: replaying intent",
      user_id: user_id,
      conversation_id: conversation_id,
      channel: channel
    )

    # Ensure the engine is running for this conversation
    case ensure_engine_started(conversation_id, user_id, channel) do
      :ok ->
        case Engine.send_message(conversation_id, message) do
          {:ok, response_text} ->
            deliver_reply(channel, response_text, reply_context)
            :ok

          {:error, reason} ->
            Logger.error("PendingIntentWorker: engine processing failed",
              conversation_id: conversation_id,
              reason: inspect(reason)
            )

            {:error, reason}
        end

      {:error, reason} ->
        Logger.error("PendingIntentWorker: failed to start engine",
          conversation_id: conversation_id,
          reason: inspect(reason)
        )

        {:error, reason}
    end
  end

  defp ensure_engine_started(conversation_id, user_id, channel) do
    case Engine.get_state(conversation_id) do
      {:ok, _state} ->
        :ok

      {:error, :not_found} ->
        opts = [
          user_id: user_id,
          channel: channel || "google_chat",
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
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp deliver_reply("google_chat", response_text, reply_context) do
    space_id = reply_context["space_id"]

    if space_id do
      opts =
        case reply_context["thread_name"] do
          nil -> []
          thread -> [thread_name: thread]
        end

      case Assistant.Integrations.Google.Chat.send_message(space_id, response_text, opts) do
        {:ok, _} ->
          Logger.debug("PendingIntentWorker: reply sent via Google Chat",
            space_id: space_id
          )

        {:error, reason} ->
          Logger.error("PendingIntentWorker: failed to send reply",
            space_id: space_id,
            reason: inspect(reason)
          )
      end
    else
      Logger.warning("PendingIntentWorker: no space_id in reply_context, cannot deliver reply")
    end
  end

  # Fallback for unknown channels — log but don't fail the job
  defp deliver_reply(channel, _response_text, _reply_context) do
    Logger.warning("PendingIntentWorker: unsupported channel for reply delivery",
      channel: channel
    )
  end
end
