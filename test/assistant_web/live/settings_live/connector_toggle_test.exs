defmodule AssistantWeb.SettingsLive.ConnectorToggleTest do
  @moduledoc """
  Tests for the toggle_connector LiveView event with non-Telegram connectors.

  Verifies the full event path: ensure_linked_user -> set_enabled_for_user -> reload.
  """
  use AssistantWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Assistant.AccountsFixtures

  alias Assistant.SettingsUserConnectorStates

  test "toggle_connector enables HubSpot connector for linked user", %{conn: conn} do
    settings_user = settings_user_fixture(%{email: unique_settings_user_email()})
    conn = log_in_settings_user(conn, settings_user)

    {:ok, lv, _html} = live(conn, ~p"/settings/apps")

    # Send toggle_connector event directly (element may be disabled if admin
    # hasn't configured HubSpot, but the event handler processes regardless)
    html =
      render_click(lv, "toggle_connector", %{
        "group" => "hubspot",
        "enabled" => "true",
        "app_id" => "hubspot"
      })

    assert html =~ "HubSpot enabled."

    # Verify the connector state was persisted
    reloaded = Assistant.Accounts.get_settings_user!(settings_user.id)
    assert is_binary(reloaded.user_id)

    assert SettingsUserConnectorStates.enabled_for_user?(reloaded.user_id, "hubspot") == true
  end

  test "toggle_connector disables a previously enabled connector", %{conn: conn} do
    settings_user = settings_user_fixture(%{email: unique_settings_user_email()})
    conn = log_in_settings_user(conn, settings_user)

    {:ok, lv, _html} = live(conn, ~p"/settings/apps")

    # Enable first
    _ =
      render_click(lv, "toggle_connector", %{
        "group" => "hubspot",
        "enabled" => "true",
        "app_id" => "hubspot"
      })

    # Then disable
    html =
      render_click(lv, "toggle_connector", %{
        "group" => "hubspot",
        "enabled" => "false",
        "app_id" => "hubspot"
      })

    assert html =~ "HubSpot disabled."

    reloaded = Assistant.Accounts.get_settings_user!(settings_user.id)
    assert SettingsUserConnectorStates.enabled_for_user?(reloaded.user_id, "hubspot") == false
  end
end
