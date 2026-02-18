# lib/assistant_web/controllers/webhook_controller.ex — Webhook placeholder endpoints.
#
# Placeholder controller for channel webhook endpoints.
# Each action will be replaced by dedicated controllers as channels are implemented.

defmodule AssistantWeb.WebhookController do
  use AssistantWeb, :controller

  @doc "Telegram webhook endpoint — placeholder."
  def telegram(conn, _params) do
    json(conn, %{status: "ok"})
  end

  @doc "Google Chat webhook endpoint — placeholder."
  def google_chat(conn, _params) do
    json(conn, %{status: "ok"})
  end
end
