# lib/assistant/integrations/telegram/client.ex — Telegram Bot API HTTP client.
#
# Provides functions for interacting with the Telegram Bot API via Req.
# Used by the Telegram channel adapter for sending replies, typing indicators,
# and webhook management.
#
# Related files:
#   - lib/assistant/channels/telegram.ex (channel adapter that calls this)
#   - lib/assistant_web/controllers/telegram_controller.ex (webhook handler)
#   - lib/assistant_web/plugs/telegram_auth.ex (webhook verification)

defmodule Assistant.Integrations.Telegram.Client do
  @moduledoc """
  Telegram Bot API HTTP client.

  Sends requests to the Telegram Bot API using `Req`. The bot token is read
  from application config (`:telegram_bot_token`).

  ## Usage

      # Send a message
      Telegram.Client.send_message("12345678", "Hello!")

      # Send a typing indicator
      Telegram.Client.send_chat_action("12345678", "typing")

      # Set up webhook
      Telegram.Client.set_webhook("https://example.com/webhooks/telegram",
        secret_token: "my-secret"
      )
  """

  alias Assistant.IntegrationSettings

  require Logger

  @default_base_url "https://api.telegram.org"
  @max_message_length 4096

  @doc """
  Send a text message to a Telegram chat.

  ## Parameters

    * `chat_id` - The chat ID (as string or integer)
    * `text` - The message text (max 4096 characters)
    * `opts` - Options:
      * `:reply_to_message_id` - Message ID to reply to (for threading)
      * `:parse_mode` - Parse mode (default: `"Markdown"`)

  ## Returns

    * `{:ok, result}` — The sent message object
    * `{:error, reason}` — API or network error
  """
  @spec send_message(String.t() | integer(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def send_message(chat_id, text, opts \\ []) do
    truncated_text = truncate_message(text)
    reply_to = Keyword.get(opts, :reply_to_message_id)
    parse_mode = Keyword.get(opts, :parse_mode, "Markdown")

    body =
      %{chat_id: chat_id, text: truncated_text, parse_mode: parse_mode}
      |> maybe_put(:reply_to_message_id, reply_to)

    post("sendMessage", body)
  end

  @doc """
  Send a chat action (e.g., "typing") to a Telegram chat.

  ## Parameters

    * `chat_id` - The chat ID
    * `action` - The action string (e.g., `"typing"`, `"upload_document"`)
  """
  @spec send_chat_action(String.t() | integer(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def send_chat_action(chat_id, action) do
    post("sendChatAction", %{chat_id: chat_id, action: action})
  end

  @doc """
  Register a webhook URL with Telegram.

  ## Parameters

    * `url` - The HTTPS webhook URL
    * `opts` - Options:
      * `:secret_token` - Secret token for request verification (1-256 chars)
      * `:max_connections` - Max simultaneous connections (1-100, default 40)
      * `:allowed_updates` - List of update types to receive
  """
  @spec set_webhook(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def set_webhook(url, opts \\ []) do
    body =
      %{url: url}
      |> maybe_put(:secret_token, Keyword.get(opts, :secret_token))
      |> maybe_put(:max_connections, Keyword.get(opts, :max_connections))
      |> maybe_put(:allowed_updates, Keyword.get(opts, :allowed_updates))

    post("setWebhook", body)
  end

  @doc "Remove the current webhook."
  @spec delete_webhook() :: {:ok, map()} | {:error, term()}
  def delete_webhook do
    post("deleteWebhook", %{})
  end

  @doc "Get basic information about the bot (health check / identity)."
  @spec get_me() :: {:ok, map()} | {:error, term()}
  def get_me do
    get("getMe")
  end

  # --- HTTP Helpers ---

  defp post(method, body) do
    with {:ok, token} <- get_token() do
      url = "#{base_url()}/bot#{token}/#{method}"

      case Req.post(url, json: body) do
        {:ok, %Req.Response{status: 200, body: %{"ok" => true, "result" => result}}} ->
          {:ok, result}

        {:ok, %Req.Response{status: status, body: %{"ok" => false, "description" => desc}}} ->
          Logger.warning("Telegram API error",
            method: method,
            status: status,
            description: desc
          )

          {:error, {:api_error, status, desc}}

        {:ok, %Req.Response{status: status, body: body}} ->
          Logger.warning("Telegram API unexpected response",
            method: method,
            status: status,
            body: inspect(body)
          )

          {:error, {:api_error, status, body}}

        {:error, reason} ->
          Logger.error("Telegram API request failed",
            method: method,
            reason: inspect(reason)
          )

          {:error, {:request_failed, reason}}
      end
    end
  end

  defp get(method) do
    with {:ok, token} <- get_token() do
      url = "#{base_url()}/bot#{token}/#{method}"

      case Req.get(url) do
        {:ok, %Req.Response{status: 200, body: %{"ok" => true, "result" => result}}} ->
          {:ok, result}

        {:ok, %Req.Response{status: status, body: %{"ok" => false, "description" => desc}}} ->
          Logger.warning("Telegram API error",
            method: method,
            status: status,
            description: desc
          )

          {:error, {:api_error, status, desc}}

        {:ok, %Req.Response{status: status, body: body}} ->
          Logger.warning("Telegram API unexpected response",
            method: method,
            status: status,
            body: inspect(body)
          )

          {:error, {:api_error, status, body}}

        {:error, reason} ->
          Logger.error("Telegram API request failed",
            method: method,
            reason: inspect(reason)
          )

          {:error, {:request_failed, reason}}
      end
    end
  end

  defp base_url do
    Application.get_env(:assistant, :telegram_api_base_url, @default_base_url)
  end

  defp get_token do
    case IntegrationSettings.get(:telegram_bot_token) do
      nil ->
        Logger.error("telegram_bot_token not configured")
        {:error, :token_not_configured}

      token ->
        {:ok, token}
    end
  end

  defp truncate_message(text) do
    if String.length(text) <= @max_message_length do
      text
    else
      max = @max_message_length - 40
      String.slice(text, 0, max) <> "\n\n[Message truncated]"
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
