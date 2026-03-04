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
  alias Assistant.Integrations.Telegram.AccountLink

  require Logger

  @link_success_message "Telegram connected. You can now chat with this bot."
  @link_invalid_message "This Telegram connect link is invalid or expired."
  @link_conflict_message "This Telegram account is already linked to another user."
  @link_existing_message "Disconnect your current Telegram account before linking a new one."

  @doc """
  Handle a Telegram webhook Update.

  The TelegramAuth plug has already verified the secret token by this point.
  """
  def webhook(conn, params) do
    case TelegramAdapter.normalize(params) do
      {:ok, message} ->
        cond do
          telegram_start?(message) ->
            handle_start_message(message)

          AccountLink.authorized?(message) ->
            Logger.info("Telegram message received",
              chat_id: message.space_id,
              user_id: message.user_id,
              has_command: message.slash_command != nil
            )

            Dispatcher.dispatch(TelegramAdapter, message)

          true ->
            Logger.info("Ignoring unauthorized Telegram message",
              chat_id: message.space_id,
              user_id: message.user_id,
              chat_type: message.metadata["chat_type"]
            )
        end

        # Telegram expects 200 — always acknowledge
        json(conn, %{})

      {:error, :ignored} ->
        # Non-text update (edited_message, callback_query, etc.) — acknowledge
        json(conn, %{})
    end
  end

  defp handle_start_message(message) do
    case AccountLink.consume_start_link(message) do
      {:ok, :linked} ->
        TelegramAdapter.send_reply(message.space_id, @link_success_message)

      {:error, :missing_token} ->
        if AccountLink.authorized?(message) do
          TelegramAdapter.send_reply(message.space_id, @link_success_message)
        end

      {:error, reason}
      when reason in [:invalid_token, :expired_token, :already_used_token] ->
        TelegramAdapter.send_reply(message.space_id, @link_invalid_message)

      {:error, :already_linked} ->
        TelegramAdapter.send_reply(message.space_id, @link_conflict_message)

      {:error, :user_already_linked} ->
        TelegramAdapter.send_reply(message.space_id, @link_existing_message)

      {:error, :not_private_chat} ->
        :ok

      {:error, reason} ->
        Logger.warning("Telegram start link handling failed", reason: inspect(reason))
    end
  end

  defp telegram_start?(message), do: message.slash_command == "/start"
end
