# lib/assistant_web/controllers/google_chat_controller.ex — Google Chat webhook controller.
#
# Handles incoming Google Chat webhook events. JWT verification is performed
# by the GoogleChatAuth plug (applied in the router). This controller
# normalizes events, handles Google Chat-specific lifecycle events (welcome,
# removal), and delegates message processing to the shared Dispatcher.
#
# Related files:
#   - lib/assistant_web/plugs/google_chat_auth.ex (JWT verification)
#   - lib/assistant/channels/google_chat.ex (event normalization + reply sending)
#   - lib/assistant/channels/dispatcher.ex (shared async dispatch logic)
#   - lib/assistant_web/router.ex (route definition)

defmodule AssistantWeb.GoogleChatController do
  @moduledoc """
  Webhook controller for Google Chat events.

  ## Flow

    1. GoogleChatAuth plug verifies the JWT (returns 401 on failure)
    2. Controller normalizes the raw event via `Channels.GoogleChat`
    3. For `ADDED_TO_SPACE`: returns a synchronous welcome message
    4. For `MESSAGE`/`APP_COMMAND`: delegates to `Channels.Dispatcher` for
       async processing and returns `{"text": "Processing..."}` immediately
    5. For ignored events: returns 200 with empty body
  """

  use AssistantWeb, :controller

  alias Assistant.Channels.Dispatcher
  alias Assistant.Channels.GoogleChat, as: ChatAdapter

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
    Logger.info("Google Chat webhook received",
      event_type: params["type"],
      keys: Map.keys(params) |> Enum.join(", ")
    )

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

  # MESSAGE / APP_COMMAND: delegate to the shared Dispatcher for async processing.
  defp handle_normalized(conn, message, _params) do
    Logger.info("Google Chat message received",
      space_id: message.space_id,
      user_id: message.user_id,
      event_type: message.metadata["event_type"],
      has_slash_command: message.slash_command != nil
    )

    Dispatcher.dispatch(ChatAdapter, message)

    json(conn, %{"text" => "Processing..."})
  end
end
