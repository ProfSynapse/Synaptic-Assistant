defmodule AssistantWeb.StripeWebhookController do
  use AssistantWeb, :controller

  alias Assistant.Billing

  def webhook(conn, _params) do
    signature_header = List.first(get_req_header(conn, "stripe-signature"))
    raw_body = conn.private[:raw_body]

    case Billing.process_webhook(signature_header, raw_body) do
      :ok ->
        json(conn, %{received: true})

      {:error, :invalid_signature} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "Invalid signature"})

      {:error, :stale_signature} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "Stale signature"})

      {:error, _reason} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "Invalid webhook"})
    end
  end
end
