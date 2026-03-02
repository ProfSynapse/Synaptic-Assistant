defmodule AssistantWeb.AdminLiveIntegrationSettingsTest do
  use AssistantWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Assistant.AccountsFixtures

  alias Assistant.Accounts
  alias Assistant.IntegrationSettings
  alias Assistant.IntegrationSettings.Cache

  # Set up an admin user and clean ETS cache per test
  setup %{conn: conn} do
    # Create and bootstrap an admin user
    settings_user = settings_user_fixture()
    {:ok, admin_user} = Accounts.bootstrap_admin_access(settings_user)
    conn = log_in_settings_user(conn, admin_user)

    # Clear ETS for test isolation (don't restart the GenServer)
    Cache.invalidate_all()

    %{conn: conn, admin_user: admin_user}
  end

  # After put/3, PubSub broadcast triggers Cache invalidation on the same node.
  # Re-warm so subsequent reads via the LiveView see the value.
  defp settle_cache do
    Process.sleep(50)
    Cache.warm()
  end

  describe "admin integrations section" do
    test "renders Integrations heading for admin users", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/admin")

      assert html =~ "Integrations"
      assert html =~ "Configure API keys and tokens"
    end

    test "renders all integration groups", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/admin")

      assert html =~ "AI Providers"
      assert html =~ "Google Workspace"
      assert html =~ "Telegram"
      assert html =~ "Slack"
      assert html =~ "Discord"
      assert html =~ "Google Chat"
      assert html =~ "HubSpot"
      assert html =~ "ElevenLabs"
    end

    test "renders key labels and help text", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/admin")

      assert html =~ "OpenRouter API Key"
      assert html =~ "openrouter.ai/settings/keys"
      assert html =~ "Bot Token"
      assert html =~ "@BotFather"
    end

    test "shows source badges", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/admin")

      # openrouter_api_key is set via env var in test.exs
      assert html =~ "Environment"
      # hubspot has no config at all
      assert html =~ "Not Set"
    end
  end

  describe "save_integration event" do
    test "saves a value and shows success flash", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/admin")

      html =
        lv
        |> form("#form-hubspot_api_key", %{"key" => "hubspot_api_key", "value" => "hk_test_12345"})
        |> render_submit()

      assert html =~ "Integration setting saved."
    end

    test "rejects blank value", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/admin")

      html =
        lv
        |> form("#form-hubspot_api_key", %{"key" => "hubspot_api_key", "value" => ""})
        |> render_submit()

      assert html =~ "Value cannot be blank"
    end

    test "rejects whitespace-only value", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/admin")

      html =
        lv
        |> form("#form-hubspot_api_key", %{"key" => "hubspot_api_key", "value" => "   "})
        |> render_submit()

      assert html =~ "Value cannot be blank"
    end

    test "saved value is retrievable via IntegrationSettings.get/1", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/admin")

      lv
      |> form("#form-hubspot_api_key", %{"key" => "hubspot_api_key", "value" => "hk_live_abc"})
      |> render_submit()

      settle_cache()
      assert IntegrationSettings.get(:hubspot_api_key) == "hk_live_abc"
    end

    test "saving shows Database badge on re-rendered page", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/admin")

      lv
      |> form("#form-hubspot_api_key", %{"key" => "hubspot_api_key", "value" => "hk_test_12345"})
      |> render_submit()

      # Due to PubSub race, the immediate render may not show "Database" badge.
      # Re-warm cache and re-mount the page to verify the badge appears.
      settle_cache()
      {:ok, _lv, html} = live(conn, ~p"/admin")
      assert html =~ "Database"
    end
  end

  describe "delete_integration event" do
    test "delete shows success flash", %{conn: conn} do
      # First save a DB value
      {:ok, _} = IntegrationSettings.put(:openrouter_api_key, "db-override-for-delete")
      settle_cache()

      {:ok, lv, _html} = live(conn, ~p"/admin")

      # Click the delete/revert button
      html =
        lv
        |> element("button[phx-click='delete_integration'][phx-value-key='openrouter_api_key']")
        |> render_click()

      assert html =~ "reverted to environment variable"
    end

    test "delete button only shows for DB-sourced settings", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/admin")

      # hubspot is :none — no delete button
      refute html =~ "phx-value-key=\"hubspot_api_key\""
    end
  end

  describe "non-admin access" do
    test "non-admin user is redirected away from admin page", %{admin_user: admin_user} do
      # Add a second user to the allowlist so they can register
      non_admin_email = unique_settings_user_email()

      Accounts.upsert_settings_user_allowlist_entry(
        %{email: non_admin_email, active: true, is_admin: false, scopes: ["chat"]},
        admin_user
      )

      non_admin = settings_user_fixture(%{email: non_admin_email})
      conn = log_in_settings_user(Phoenix.ConnTest.build_conn(), non_admin)

      {:error, {redirect_type, %{to: path, flash: flash}}} = live(conn, ~p"/admin")

      assert redirect_type in [:redirect, :live_redirect]
      assert path == "/settings"
      assert flash["error"] =~ "permission"
    end
  end

  describe "masked display security" do
    test "raw secret values are never in rendered HTML", %{conn: conn} do
      secret = "sk-super-secret-value-that-should-not-appear"
      {:ok, _} = IntegrationSettings.put(:hubspot_api_key, secret)
      settle_cache()

      {:ok, _lv, html} = live(conn, ~p"/admin")

      # The full secret should NEVER appear in the HTML
      refute html =~ secret
      # But the masked version should be there
      assert html =~ "****pear"
    end

    test "non-secret values are shown in full", %{conn: conn} do
      {:ok, _} = IntegrationSettings.put(:discord_application_id, "1234567890")
      settle_cache()

      {:ok, _lv, html} = live(conn, ~p"/admin")

      assert html =~ "1234567890"
    end
  end
end
