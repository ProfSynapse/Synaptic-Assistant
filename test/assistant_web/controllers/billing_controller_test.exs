defmodule AssistantWeb.BillingControllerTest do
  use AssistantWeb.ConnCase, async: false

  alias Assistant.Billing

  import Assistant.AccountsFixtures

  setup %{conn: conn} do
    bypass = Bypass.open()
    previous_base_url = Application.get_env(:assistant, :stripe_api_base_url)
    previous_secret = Application.get_env(:assistant, :stripe_secret_key)
    previous_price = Application.get_env(:assistant, :stripe_pro_price_id)

    Application.put_env(:assistant, :stripe_api_base_url, "http://localhost:#{bypass.port}")
    Application.put_env(:assistant, :stripe_secret_key, "sk_test_123")
    Application.put_env(:assistant, :stripe_pro_price_id, "price_pro_123")

    on_exit(fn ->
      restore_env(:stripe_api_base_url, previous_base_url)
      restore_env(:stripe_secret_key, previous_secret)
      restore_env(:stripe_pro_price_id, previous_price)
    end)

    settings_user = settings_user_fixture()
    {:ok, _} = Billing.ensure_billing_account(settings_user)

    %{
      conn: log_in_settings_user(conn, settings_user),
      bypass: bypass,
      settings_user: settings_user
    }
  end

  describe "POST /billing/checkout/pro" do
    test "redirects to Stripe checkout for the shared workspace", %{conn: conn, bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/v1/customers", fn conn ->
        conn
        |> Plug.Conn.put_resp_header("content-type", "application/json")
        |> Plug.Conn.resp(200, ~s({"id":"cus_123"}))
      end)

      Bypass.expect_once(bypass, "POST", "/v1/checkout/sessions", fn conn ->
        conn
        |> Plug.Conn.put_resp_header("content-type", "application/json")
        |> Plug.Conn.resp(200, ~s({"id":"cs_123","url":"https://checkout.stripe.test/session"}))
      end)

      conn = post(conn, "/billing/checkout/pro")

      assert redirected_to(conn, 302) == "https://checkout.stripe.test/session"
    end
  end

  describe "POST /billing/portal" do
    test "redirects to the Stripe customer portal", %{
      conn: conn,
      bypass: bypass,
      settings_user: settings_user
    } do
      {:ok, {_, billing_account}} = Billing.ensure_billing_account(settings_user)

      billing_account
      |> Assistant.Schemas.BillingAccount.changeset(%{stripe_customer_id: "cus_123"})
      |> Assistant.Repo.update!()

      Bypass.expect_once(bypass, "POST", "/v1/billing_portal/sessions", fn conn ->
        conn
        |> Plug.Conn.put_resp_header("content-type", "application/json")
        |> Plug.Conn.resp(200, ~s({"url":"https://billing.stripe.test/portal"}))
      end)

      conn = post(conn, "/billing/portal")

      assert redirected_to(conn, 302) == "https://billing.stripe.test/portal"
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:assistant, key)
  defp restore_env(key, value), do: Application.put_env(:assistant, key, value)
end
