defmodule AssistantWeb.SettingsLive.AdminIntegrationDetailTest do
  use AssistantWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Assistant.AccountsFixtures

  describe "admin integration detail pages" do
    setup %{conn: conn} do
      admin = admin_settings_user_fixture(%{email: unique_settings_user_email()})
      conn = log_in_settings_user(conn, admin)

      %{conn: conn}
    end

    test "admin section renders per-integration manage links", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/settings/admin")

      assert html =~ "Manage Integration"
      assert html =~ "/settings/admin/integrations/hubspot"
      assert html =~ "/settings/admin/integrations/google_chat"
    end

    test "hubspot detail page includes setup steps and scoped credential fields", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/settings/admin/integrations/hubspot")

      assert html =~ "HubSpot Integration"
      assert html =~ "Setup Instructions"
      assert html =~ "Open developer console"
      assert html =~ "View setup guide"
      assert html =~ "Private App Token"
      refute html =~ "Slack Integration"
      refute html =~ "Signing Secret"
    end
  end

  test "non-admin is redirected from admin integration detail page", %{conn: conn} do
    non_admin = settings_user_fixture(%{email: unique_settings_user_email()})
    conn = log_in_settings_user(conn, non_admin)

    assert {:error, {:live_redirect, %{to: path, flash: flash}}} =
             live(conn, ~p"/settings/admin/integrations/hubspot")

    assert path == ~p"/settings"
    assert flash["error"] == "You do not have permission to access admin."
  end
end
