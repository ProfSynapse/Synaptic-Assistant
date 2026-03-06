defmodule AssistantWeb.SettingsLive.IntegrationToggleTest do
  @moduledoc """
  Tests for the toggle_integration LiveView event (admin gate).

  Verifies that admins can toggle integration groups and non-admins are rejected.
  """
  use AssistantWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Assistant.AccountsFixtures

  alias Assistant.IntegrationSettings
  alias Assistant.IntegrationSettings.Cache

  setup do
    # Ensure ETS cache is fresh for this test's sandbox DB
    Cache.invalidate_all()
    Cache.warm()

    on_exit(fn ->
      Cache.invalidate_all()
      Cache.warm()
    end)

    :ok
  end

  test "admin can toggle hubspot integration enabled", %{conn: conn} do
    admin = admin_settings_user_fixture(%{email: unique_settings_user_email()})
    conn = log_in_settings_user(conn, admin)

    {:ok, lv, _html} = live(conn, ~p"/settings/admin")

    # Send toggle_integration event directly
    _html =
      render_click(lv, "toggle_integration", %{
        "group" => "hubspot",
        "enabled" => "true"
      })

    # Allow PubSub cache invalidation to propagate, then re-warm
    Process.sleep(10)
    Cache.warm()

    assert IntegrationSettings.get(:hubspot_enabled) == "true"
  end

  test "non-admin receives authorization error on toggle_integration", %{conn: conn} do
    non_admin = settings_user_fixture(%{email: unique_settings_user_email()})
    conn = log_in_settings_user(conn, non_admin)

    # Non-admin navigates to apps (not admin) — toggle_integration events
    # still reach the handler but the admin gate rejects them
    {:ok, lv, _html} = live(conn, ~p"/settings/apps")

    html =
      render_click(lv, "toggle_integration", %{
        "group" => "hubspot",
        "enabled" => "true"
      })

    assert html =~ "Not authorized."
  end
end
