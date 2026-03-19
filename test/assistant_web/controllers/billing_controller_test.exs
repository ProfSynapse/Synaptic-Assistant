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

  describe "GET /pricing/free" do
    test "redirects signed-out users to registration" do
      conn = build_conn() |> get(~p"/pricing/free")

      assert redirected_to(conn) == ~p"/settings_users/register"
      assert get_session(conn, :settings_user_return_to) == ~p"/workspace"
    end

    test "self-hosted mode skips the pricing entrypoint" do
      previous_mode = Application.get_env(:assistant, :deployment_mode)
      Application.put_env(:assistant, :deployment_mode, :self_hosted)

      on_exit(fn ->
        Application.put_env(:assistant, :deployment_mode, previous_mode || :cloud)
      end)

      conn = build_conn() |> get(~p"/pricing/free")

      assert redirected_to(conn) == ~p"/settings_users/log-in"

      assert Phoenix.Flash.get(conn.assigns.flash, :info) ==
               "Stripe billing is disabled in self-hosted deployments."
    end
  end

  describe "GET /pricing/pro" do
    test "redirects signed-out users to registration and preserves pro intent" do
      conn = build_conn() |> get(~p"/pricing/pro")

      assert redirected_to(conn) == ~p"/settings_users/register"
      assert get_session(conn, :settings_user_return_to) == ~p"/pricing/pro"
    end

    test "redirects signed-in users to Stripe checkout", %{conn: conn, bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/v1/customers", fn conn ->
        conn
        |> Plug.Conn.put_resp_header("content-type", "application/json")
        |> Plug.Conn.resp(200, ~s({"id":"cus_456"}))
      end)

      Bypass.expect_once(bypass, "POST", "/v1/checkout/sessions", fn conn ->
        conn
        |> Plug.Conn.put_resp_header("content-type", "application/json")
        |> Plug.Conn.resp(200, ~s({"id":"cs_456","url":"https://checkout.stripe.test/pro"}))
      end)

      conn = get(conn, ~p"/pricing/pro")

      assert redirected_to(conn, 302) == "https://checkout.stripe.test/pro"
    end

    test "self-hosted mode skips the pro pricing entrypoint" do
      previous_mode = Application.get_env(:assistant, :deployment_mode)
      Application.put_env(:assistant, :deployment_mode, :self_hosted)

      on_exit(fn ->
        Application.put_env(:assistant, :deployment_mode, previous_mode || :cloud)
      end)

      conn = build_conn() |> get(~p"/pricing/pro")

      assert redirected_to(conn) == ~p"/settings_users/log-in"

      assert Phoenix.Flash.get(conn.assigns.flash, :info) ==
               "Stripe billing is disabled in self-hosted deployments."
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
