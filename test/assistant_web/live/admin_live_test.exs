defmodule AssistantWeb.AdminLiveTest do
  use AssistantWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  import Assistant.AccountsFixtures

  alias Assistant.Accounts

  test "first authenticated user can bootstrap admin access", %{conn: conn} do
    settings_user = settings_user_fixture()
    conn = log_in_settings_user(conn, settings_user)

    {:ok, lv, html} = live(conn, ~p"/admin")

    assert html =~ "Initial Admin Bootstrap"

    html =
      lv
      |> element("#claim-admin-btn")
      |> render_click()

    assert html =~ "Allow List"

    reloaded = Accounts.get_settings_user!(settings_user.id)
    assert reloaded.is_admin
    assert Enum.sort(reloaded.access_scopes) == Enum.sort(Accounts.managed_access_scopes())
  end
end
