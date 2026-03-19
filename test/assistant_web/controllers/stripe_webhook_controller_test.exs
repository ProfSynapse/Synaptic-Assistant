defmodule AssistantWeb.StripeWebhookControllerTest do
  use AssistantWeb.ConnCase, async: false

  alias Assistant.Billing
  alias Assistant.Repo
  alias Assistant.Schemas.BillingAccount

  import Assistant.AccountsFixtures

  setup do
    prev = Application.get_env(:assistant, :stripe_webhook_secret)
    Application.put_env(:assistant, :stripe_webhook_secret, "whsec_test")

    on_exit(fn ->
      if prev do
        Application.put_env(:assistant, :stripe_webhook_secret, prev)
      else
        Application.delete_env(:assistant, :stripe_webhook_secret)
      end
    end)

    settings_user = settings_user_fixture()
    {:ok, {_, billing_account}} = Billing.ensure_billing_account(settings_user)

    billing_account =
      billing_account
      |> BillingAccount.changeset(%{stripe_customer_id: "cus_123"})
      |> Repo.update!()

    %{billing_account: billing_account}
  end

  test "updates tenant billing state from a valid Stripe webhook", %{
    conn: conn,
    billing_account: billing_account
  } do
    payload = %{
      "type" => "customer.subscription.updated",
      "data" => %{
        "object" => %{
          "id" => "sub_123",
          "customer" => "cus_123",
          "status" => "active",
          "current_period_end" => 1_773_935_200,
          "items" => %{
            "data" => [
              %{
                "id" => "si_123",
                "price" => %{"id" => "price_pro_123"}
              }
            ]
          },
          "metadata" => %{"billing_account_id" => billing_account.id}
        }
      }
    }

    body = Jason.encode!(payload)

    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> put_req_header("stripe-signature", signature_for(body, "whsec_test"))
      |> post("/webhooks/stripe", body)

    assert json_response(conn, 200) == %{"received" => true}

    billing_account = Repo.get!(BillingAccount, billing_account.id)
    assert billing_account.plan == "pro"
    assert billing_account.stripe_subscription_id == "sub_123"
  end

  test "rejects an invalid Stripe signature", %{conn: conn} do
    timestamp = Integer.to_string(System.system_time(:second))

    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> put_req_header("stripe-signature", "t=#{timestamp},v1=bad")
      |> post("/webhooks/stripe", ~s({"type":"customer.subscription.updated"}))

    assert json_response(conn, 400) == %{"error" => "Invalid signature"}
  end

  defp signature_for(raw_body, secret) do
    timestamp = Integer.to_string(System.system_time(:second))

    digest =
      :crypto.mac(:hmac, :sha256, secret, "#{timestamp}.#{raw_body}")
      |> Base.encode16(case: :lower)

    "t=#{timestamp},v1=#{digest}"
  end
end
