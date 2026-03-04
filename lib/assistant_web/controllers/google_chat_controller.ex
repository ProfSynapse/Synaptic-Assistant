# lib/assistant_web/controllers/google_chat_controller.ex — Google Chat webhook controller.
#
# Handles incoming Google Chat webhook events. JWT verification is performed
# by the GoogleChatAuth plug (applied in the router). This controller
# normalizes events, handles Google Chat-specific lifecycle events (welcome,
# removal), and delegates message processing to the shared Dispatcher.
#
# Supports both v1 (legacy) and v2 (Workspace Add-on) event formats.
# Response envelope differs: v1 returns flat {"text": "..."}, v2 returns
# the hostAppDataAction wrapper. Format detection is delegated to the adapter.
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
       (auto-detects v1 vs v2 format)
    3. For `ADDED_TO_SPACE`: returns a synchronous welcome message
    4. For `MESSAGE`/`APP_COMMAND`: delegates to `Channels.Dispatcher` for
       async processing and returns a "Processing..." acknowledgment
    5. For ignored events: returns 200 with empty body
    6. Response envelope matches the incoming format (v1 flat vs v2 wrapped)
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
  Supports both v1 (top-level "type") and v2 (nested "chat") event formats.
  """
  def event(conn, params) do
    Logger.info(
      "Google Chat webhook received: type=#{inspect(params["type"])} keys=#{inspect(Map.keys(params))} v2=#{ChatAdapter.v2_format?(params)}"
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
  # Detect via normalized metadata since v2 events don't have top-level "type".
  defp handle_normalized(conn, %{metadata: %{"event_type" => "ADDED_TO_SPACE"}} = message, params) do
    Logger.info("Bot added to space",
      space_id: message.space_id,
      user: message.user_display_name
    )

    json(conn, ChatAdapter.wrap_response(@welcome_message, params))
  end

  # MESSAGE / APP_COMMAND: delegate to the shared Dispatcher for async processing.
  defp handle_normalized(conn, message, params) do
    Logger.info("Google Chat message received",
      space_id: message.space_id,
      user_id: message.user_id,
      event_type: message.metadata["event_type"],
      has_slash_command: message.slash_command != nil
    )

    Dispatcher.dispatch(ChatAdapter, message)

    json(conn, ChatAdapter.wrap_response("Processing...", params))
  end
end
