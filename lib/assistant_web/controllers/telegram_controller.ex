# lib/assistant_web/controllers/telegram_controller.ex — Telegram webhook controller.
#
# Handles incoming Telegram webhook events. Secret token verification is
# performed by the TelegramAuth plug (applied in the router). This controller
# normalizes events and delegates message processing to the shared Dispatcher.
#
# Telegram expects a 200 response for all webhook requests; non-200 responses
# cause Telegram to retry delivery.
#
# Related files:
#   - lib/assistant_web/plugs/telegram_auth.ex (secret token verification)
#   - lib/assistant/channels/telegram.ex (event normalization + reply sending)
#   - lib/assistant/channels/dispatcher.ex (shared async dispatch logic)
#   - lib/assistant_web/router.ex (route definition)

defmodule AssistantWeb.TelegramController do
  @moduledoc """
  Webhook controller for Telegram Bot API events.

  ## Flow

    1. TelegramAuth plug verifies the secret token header (returns 401 on failure)
    2. Controller normalizes the raw Update via `Channels.Telegram`
    3. For text messages: delegates to `Channels.Dispatcher` for async processing
    4. For ignored updates: returns 200 with empty JSON object
    5. Always returns 200 to prevent Telegram from retrying
  """

  use AssistantWeb, :controller

  alias Assistant.Channels.Dispatcher
  alias Assistant.Channels.Telegram, as: TelegramAdapter

  require Logger

  @doc """
  Handle a Telegram webhook Update.

  The TelegramAuth plug has already verified the secret token by this point.
  """
  def webhook(conn, params) do
    case TelegramAdapter.normalize(params) do
      {:ok, message} ->
        Logger.info("Telegram message received",
          chat_id: message.space_id,
          user_id: message.user_id,
          has_command: message.slash_command != nil
        )

        Dispatcher.dispatch(TelegramAdapter, message)

        # Telegram expects 200 — always acknowledge
        json(conn, %{})

      {:error, :ignored} ->
        # Non-text update (edited_message, callback_query, etc.) — acknowledge
        json(conn, %{})
    end
  end
end
