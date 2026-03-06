defmodule AssistantWeb.SettingsLive.PersonalSkillToggleTest do
  @moduledoc """
  Tests for the toggle_personal_skill LiveView event.

  Verifies the full event path: ensure_linked_user -> set_enabled_for_user -> reload.
  """
  use AssistantWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Assistant.AccountsFixtures

  alias Assistant.UserSkillOverrides

  test "toggle_personal_skill disables a skill for linked user", %{conn: conn} do
    settings_user = settings_user_fixture(%{email: unique_settings_user_email()})
    conn = log_in_settings_user(conn, settings_user)

    # Navigate to an app detail page where personal skill toggles are rendered
    {:ok, lv, _html} = live(conn, ~p"/settings/apps/google_workspace")

    # Send toggle event directly — the element may be hidden if integration
    # isn't configured, but the event handler processes regardless
    html =
      render_click(lv, "toggle_personal_skill", %{
        "skill" => "email.send",
        "enabled" => "false"
      })

    assert html =~ "Send updated"

    # Verify the override was persisted
    reloaded = Assistant.Accounts.get_settings_user!(settings_user.id)
    assert is_binary(reloaded.user_id)

    assert UserSkillOverrides.enabled_for_user?(reloaded.user_id, "email.send", default: true) ==
             false
  end

  test "toggle_personal_skill re-enables a previously disabled skill", %{conn: conn} do
    settings_user = settings_user_fixture(%{email: unique_settings_user_email()})
    conn = log_in_settings_user(conn, settings_user)

    {:ok, lv, _html} = live(conn, ~p"/settings/apps/google_workspace")

    # Disable first
    _ =
      render_click(lv, "toggle_personal_skill", %{
        "skill" => "email.send",
        "enabled" => "false"
      })

    # Re-enable
    html =
      render_click(lv, "toggle_personal_skill", %{
        "skill" => "email.send",
        "enabled" => "true"
      })

    assert html =~ "Send updated"

    reloaded = Assistant.Accounts.get_settings_user!(settings_user.id)

    assert UserSkillOverrides.enabled_for_user?(reloaded.user_id, "email.send", default: true) ==
             true
  end
end
