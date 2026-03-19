defmodule AssistantWeb.MarketingLiveTest do
  use AssistantWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Assistant.AccountsFixtures

  setup do
    previous_mode = Application.get_env(:assistant, :deployment_mode)

    on_exit(fn ->
      Application.put_env(:assistant, :deployment_mode, previous_mode || :cloud)
    end)

    :ok
  end

  test "self-hosted mode redirects signed-out root traffic to login", %{conn: conn} do
    admin_settings_user_fixture()
    Application.put_env(:assistant, :deployment_mode, :self_hosted)

    assert {:error, redirect} = live(conn, ~p"/")
    assert {:redirect, %{to: path}} = redirect
    assert path == ~p"/settings_users/log-in"
  end

  test "self-hosted mode redirects signed-in root traffic to the workspace", %{conn: conn} do
    admin_settings_user_fixture()
    Application.put_env(:assistant, :deployment_mode, :self_hosted)

    assert {:error, redirect} =
             conn
             |> log_in_settings_user(settings_user_fixture())
             |> live(~p"/")

    assert {:redirect, %{to: path}} = redirect
    assert path == ~p"/workspace"
  end
end
