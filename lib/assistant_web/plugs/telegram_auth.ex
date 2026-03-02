# lib/assistant_web/plugs/telegram_auth.ex — Secret token verification for Telegram webhooks.
#
# Phoenix Plug that verifies the secret token header sent by Telegram on every
# webhook request. When setting up a webhook via `setWebhook`, a `secret_token`
# is provided to Telegram, which then includes it in every request as the
# `X-Telegram-Bot-Api-Secret-Token` header.
#
# Related files:
#   - lib/assistant_web/controllers/telegram_controller.ex (consumer)
#   - lib/assistant_web/router.ex (where this plug is applied)
#   - lib/assistant/integrations/telegram/client.ex (set_webhook sends the secret)

defmodule AssistantWeb.Plugs.TelegramAuth do
  @moduledoc """
  Phoenix Plug that verifies Telegram webhook secret tokens.

  Telegram sends an `X-Telegram-Bot-Api-Secret-Token` header on every webhook
  request. This plug compares it against the configured secret using
  constant-time comparison to prevent timing attacks.

  ## Configuration

  Requires `:telegram_webhook_secret` in the `:assistant` app env:

      config :assistant, telegram_webhook_secret: "your-secret-token"

  If no secret is configured, all requests are rejected (fail-closed).
  """

  import Plug.Conn

  require Logger

  @behaviour Plug

  @header "x-telegram-bot-api-secret-token"

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    expected_secret = Application.get_env(:assistant, :telegram_webhook_secret)

    with {:ok, secret} <- get_secret_header(conn),
         :ok <- verify_secret(secret, expected_secret) do
      assign(conn, :telegram_verified, true)
    else
      {:error, reason} ->
        Logger.warning("Telegram webhook auth failed",
          reason: reason,
          remote_ip: to_string(:inet_parse.ntoa(conn.remote_ip))
        )

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(401, Jason.encode!(%{"error" => "Unauthorized"}))
        |> halt()
    end
  end

  defp get_secret_header(conn) do
    case get_req_header(conn, @header) do
      [token] when is_binary(token) and token != "" -> {:ok, token}
      _ -> {:error, :missing_secret_token}
    end
  end

  defp verify_secret(_received, nil) do
    Logger.error("telegram_webhook_secret not configured — rejecting all requests")
    {:error, :secret_not_configured}
  end

  defp verify_secret(received, expected) do
    if Plug.Crypto.secure_compare(received, expected) do
      :ok
    else
      {:error, :invalid_secret_token}
    end
  end
end
