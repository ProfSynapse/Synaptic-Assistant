# lib/assistant_web/controllers/google_chat_controller.ex — Google Chat webhook controller.
#
# Handles incoming Google Chat webhook events. JWT verification is performed
# by the GoogleChatAuth plug (applied in the router). This controller
# normalizes events, returns synchronous acknowledgments, and spawns async
# tasks for LLM processing to respect Google Chat's 30-second timeout.
#
# Related files:
#   - lib/assistant_web/plugs/google_chat_auth.ex (JWT verification)
#   - lib/assistant/channels/google_chat.ex (event normalization + reply sending)
#   - lib/assistant/orchestrator/engine.ex (conversation processing)
#   - lib/assistant_web/router.ex (route definition)

defmodule AssistantWeb.GoogleChatController do
  @moduledoc """
  Webhook controller for Google Chat events.

  ## Flow

    1. GoogleChatAuth plug verifies the JWT (returns 401 on failure)
    2. Controller normalizes the raw event via `Channels.GoogleChat`
    3. For `ADDED_TO_SPACE`: returns a synchronous welcome message
    4. For `MESSAGE`/`APP_COMMAND`: spawns an async task for orchestrator
       processing and returns `{"text": "Processing..."}` immediately
    5. The async task looks up or starts a conversation engine, sends the
       message, and posts the response back via the Chat REST API
    6. For ignored events: returns 200 with empty body
  """

  use AssistantWeb, :controller

  alias Assistant.Channels.GoogleChat, as: ChatAdapter
  alias Assistant.Integrations.Google.Chat, as: ChatClient
  alias Assistant.Orchestrator.Engine

  require Logger

  @welcome_message """
  Hello! I'm your AI assistant. I can help you with tasks, answer questions, \
  search your files, and more. Just send me a message to get started.\
  """

  @doc """
  Handle a Google Chat webhook event.

  The GoogleChatAuth plug has already verified the JWT by this point.
  """
  def event(conn, params) do
    case ChatAdapter.normalize(params) do
      {:ok, message} ->
        handle_normalized(conn, message, params)

      {:error, :ignored} ->
        # REMOVED_FROM_SPACE or unrecognized event — acknowledge silently
        send_resp(conn, 200, "")
    end
  end

  # --- Event Handlers ---

  # ADDED_TO_SPACE: return a synchronous welcome message.
  defp handle_normalized(conn, message, %{"type" => "ADDED_TO_SPACE"}) do
    Logger.info("Bot added to space",
      space_id: message.space_id,
      user: message.user_display_name
    )

    json(conn, %{"text" => @welcome_message})
  end

  # MESSAGE / APP_COMMAND: acknowledge immediately, process async.
  defp handle_normalized(conn, message, _params) do
    Logger.info("Google Chat message received",
      space_id: message.space_id,
      user_id: message.user_id,
      event_type: message.metadata["event_type"],
      has_slash_command: message.slash_command != nil
    )

    # Spawn async processing task — do not block the controller
    spawn_async_processing(message)

    json(conn, %{"text" => "Processing..."})
  end

  # --- Async Processing ---

  # Spawn a Task to process the message through the orchestrator and send
  # the response back via the Google Chat REST API. Uses Task.Supervisor
  # for crash isolation.
  defp spawn_async_processing(message) do
    Task.Supervisor.start_child(
      Assistant.Skills.TaskSupervisor,
      fn -> process_and_reply(message) end
    )
  end

  defp process_and_reply(message) do
    conversation_id = derive_conversation_id(message)

    # Ensure the engine is running for this conversation
    ensure_engine_started(conversation_id, message)

    # Send the message to the orchestrator engine
    case Engine.send_message(conversation_id, message.content) do
      {:ok, response_text} ->
        reply_opts = build_reply_opts(message)

        case ChatClient.send_message(message.space_id, response_text, reply_opts) do
          {:ok, _} ->
            Logger.debug("Google Chat reply sent",
              conversation_id: conversation_id,
              space_id: message.space_id
            )

          {:error, reason} ->
            Logger.error("Failed to send Google Chat reply",
              conversation_id: conversation_id,
              space_id: message.space_id,
              reason: inspect(reason)
            )
        end

      {:error, reason} ->
        Logger.error("Orchestrator processing failed",
          conversation_id: conversation_id,
          reason: inspect(reason)
        )

        error_text =
          "I encountered an error processing your message. Please try again."

        reply_opts = build_reply_opts(message)
        ChatClient.send_message(message.space_id, error_text, reply_opts)
    end
  rescue
    error ->
      Logger.error("Unhandled error in async Google Chat processing",
        error: inspect(error),
        stacktrace: inspect(__STACKTRACE__)
      )
  end

  # --- Helpers ---

  # Derive a stable conversation ID from the space + thread combination.
  # DMs and threads within spaces map to distinct conversations.
  defp derive_conversation_id(message) do
    base = message.space_id

    if message.thread_id do
      "gchat:#{base}:#{message.thread_id}"
    else
      "gchat:#{base}"
    end
  end

  # Start the orchestrator engine for this conversation if not already running.
  defp ensure_engine_started(conversation_id, message) do
    case Engine.get_state(conversation_id) do
      {:ok, _state} ->
        :ok

      {:error, :not_found} ->
        opts = [
          user_id: message.user_id,
          channel: "google_chat",
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
            Logger.info("Started conversation engine",
              conversation_id: conversation_id,
              user_id: message.user_id
            )

            :ok

          {:error, {:already_started, _pid}} ->
            # Race condition — another request started it between our check and start
            :ok

          {:error, reason} ->
            Logger.error("Failed to start conversation engine",
              conversation_id: conversation_id,
              reason: inspect(reason)
            )

            {:error, reason}
        end
    end
  end

  # Build reply options (thread_name for threaded replies).
  defp build_reply_opts(message) do
    if message.thread_id do
      [thread_name: message.thread_id]
    else
      []
    end
  end
end
