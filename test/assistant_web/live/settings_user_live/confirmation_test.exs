defmodule AssistantWeb.SettingsUserLive.ConfirmationTest do
  use AssistantWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Assistant.AccountsFixtures

  alias Assistant.Accounts

  setup do
    %{
      unconfirmed_settings_user: unconfirmed_settings_user_fixture(),
      confirmed_settings_user: settings_user_fixture()
    }
  end

  describe "Confirm settings_user" do
    test "renders confirmation page for unconfirmed settings_user", %{
      conn: conn,
      unconfirmed_settings_user: settings_user
    } do
      token =
        extract_settings_user_token(fn url ->
          Accounts.deliver_login_instructions(settings_user, url)
        end)

      {:ok, _lv, html} = live(conn, ~p"/settings_users/log-in/#{token}")
      assert html =~ "Confirm and stay logged in"
    end

    test "renders login page for confirmed settings_user", %{
      conn: conn,
      confirmed_settings_user: settings_user
    } do
      token =
        extract_settings_user_token(fn url ->
          Accounts.deliver_login_instructions(settings_user, url)
        end)

      {:ok, _lv, html} = live(conn, ~p"/settings_users/log-in/#{token}")
      refute html =~ "Confirm my account"
      assert html =~ "Keep me logged in on this device"
    end

    test "renders login page for already logged in settings_user", %{
      conn: conn,
      confirmed_settings_user: settings_user
    } do
      conn = log_in_settings_user(conn, settings_user)

      token =
        extract_settings_user_token(fn url ->
          Accounts.deliver_login_instructions(settings_user, url)
        end)

      {:ok, _lv, html} = live(conn, ~p"/settings_users/log-in/#{token}")
      refute html =~ "Confirm my account"
      assert html =~ "Log in"
    end

    test "confirms the given token once", %{conn: conn, unconfirmed_settings_user: settings_user} do
      token =
        extract_settings_user_token(fn url ->
          Accounts.deliver_login_instructions(settings_user, url)
        end)

      {:ok, lv, _html} = live(conn, ~p"/settings_users/log-in/#{token}")

      form = form(lv, "#confirmation_form", %{"settings_user" => %{"token" => token}})
      render_submit(form)

      conn = follow_trigger_action(form, conn)

      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~
               "SettingsUser confirmed successfully"

      assert Accounts.get_settings_user!(settings_user.id).confirmed_at
      # we are logged in now
      assert get_session(conn, :settings_user_token)
      assert redirected_to(conn) == ~p"/"

      # log out, new conn
      conn = build_conn()

      {:ok, _lv, html} =
        live(conn, ~p"/settings_users/log-in/#{token}")
        |> follow_redirect(conn, ~p"/settings_users/log-in")

      assert html =~ "Magic link is invalid or it has expired"
    end

    test "logs confirmed settings_user in without changing confirmed_at", %{
      conn: conn,
      confirmed_settings_user: settings_user
    } do
      token =
        extract_settings_user_token(fn url ->
          Accounts.deliver_login_instructions(settings_user, url)
        end)

      {:ok, lv, _html} = live(conn, ~p"/settings_users/log-in/#{token}")

      form = form(lv, "#login_form", %{"settings_user" => %{"token" => token}})
      render_submit(form)

      conn = follow_trigger_action(form, conn)

      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~
               "Welcome back!"

      assert Accounts.get_settings_user!(settings_user.id).confirmed_at ==
               settings_user.confirmed_at

      # log out, new conn
      conn = build_conn()

      {:ok, _lv, html} =
        live(conn, ~p"/settings_users/log-in/#{token}")
        |> follow_redirect(conn, ~p"/settings_users/log-in")

      assert html =~ "Magic link is invalid or it has expired"
    end

    test "raises error for invalid token", %{conn: conn} do
      {:ok, _lv, html} =
        live(conn, ~p"/settings_users/log-in/invalid-token")
        |> follow_redirect(conn, ~p"/settings_users/log-in")

      assert html =~ "Magic link is invalid or it has expired"
    end
  end
end
