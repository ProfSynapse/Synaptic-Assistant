defmodule AssistantWeb.SettingsUserSessionControllerTest do
  use AssistantWeb.ConnCase, async: true

  import Assistant.AccountsFixtures
  alias Assistant.Accounts

  setup do
    %{
      unconfirmed_settings_user: unconfirmed_settings_user_fixture(),
      settings_user: settings_user_fixture()
    }
  end

  describe "POST /settings_users/log-in - email and password" do
    test "logs the settings_user in", %{conn: conn, settings_user: settings_user} do
      settings_user = set_password(settings_user)

      conn =
        post(conn, ~p"/settings_users/log-in", %{
          "settings_user" => %{
            "email" => settings_user.email,
            "password" => valid_settings_user_password()
          }
        })

      assert get_session(conn, :settings_user_token)
      assert redirected_to(conn) == ~p"/"

      # Now do a logged in request and assert on the menu
      conn = get(conn, ~p"/")
      response = html_response(conn, 200)
      assert response =~ settings_user.email
      assert response =~ ~p"/settings_users/settings"
      assert response =~ ~p"/settings_users/log-out"
    end

    test "logs the settings_user in with remember me", %{conn: conn, settings_user: settings_user} do
      settings_user = set_password(settings_user)

      conn =
        post(conn, ~p"/settings_users/log-in", %{
          "settings_user" => %{
            "email" => settings_user.email,
            "password" => valid_settings_user_password(),
            "remember_me" => "true"
          }
        })

      assert conn.resp_cookies["_assistant_web_settings_user_remember_me"]
      assert redirected_to(conn) == ~p"/"
    end

    test "logs the settings_user in with return to", %{conn: conn, settings_user: settings_user} do
      settings_user = set_password(settings_user)

      conn =
        conn
        |> init_test_session(settings_user_return_to: "/foo/bar")
        |> post(~p"/settings_users/log-in", %{
          "settings_user" => %{
            "email" => settings_user.email,
            "password" => valid_settings_user_password()
          }
        })

      assert redirected_to(conn) == "/foo/bar"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "Welcome back!"
    end

    test "redirects to login page with invalid credentials", %{
      conn: conn,
      settings_user: settings_user
    } do
      conn =
        post(conn, ~p"/settings_users/log-in?mode=password", %{
          "settings_user" => %{"email" => settings_user.email, "password" => "invalid_password"}
        })

      assert Phoenix.Flash.get(conn.assigns.flash, :error) == "Invalid email or password"
      assert redirected_to(conn) == ~p"/settings_users/log-in"
    end
  end

  describe "POST /settings_users/log-in - magic link" do
    test "logs the settings_user in", %{conn: conn, settings_user: settings_user} do
      {token, _hashed_token} = generate_settings_user_magic_link_token(settings_user)

      conn =
        post(conn, ~p"/settings_users/log-in", %{
          "settings_user" => %{"token" => token}
        })

      assert get_session(conn, :settings_user_token)
      assert redirected_to(conn) == ~p"/"

      # Now do a logged in request and assert on the menu
      conn = get(conn, ~p"/")
      response = html_response(conn, 200)
      assert response =~ settings_user.email
      assert response =~ ~p"/settings_users/settings"
      assert response =~ ~p"/settings_users/log-out"
    end

    test "confirms unconfirmed settings_user", %{
      conn: conn,
      unconfirmed_settings_user: settings_user
    } do
      {token, _hashed_token} = generate_settings_user_magic_link_token(settings_user)
      refute settings_user.confirmed_at

      conn =
        post(conn, ~p"/settings_users/log-in", %{
          "settings_user" => %{"token" => token},
          "_action" => "confirmed"
        })

      assert get_session(conn, :settings_user_token)
      assert redirected_to(conn) == ~p"/"

      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~
               "Settings user confirmed successfully."

      assert Accounts.get_settings_user!(settings_user.id).confirmed_at

      # Now do a logged in request and assert on the menu
      conn = get(conn, ~p"/")
      response = html_response(conn, 200)
      assert response =~ settings_user.email
      assert response =~ ~p"/settings_users/settings"
      assert response =~ ~p"/settings_users/log-out"
    end

    test "redirects to login page when magic link is invalid", %{conn: conn} do
      conn =
        post(conn, ~p"/settings_users/log-in", %{
          "settings_user" => %{"token" => "invalid"}
        })

      assert Phoenix.Flash.get(conn.assigns.flash, :error) ==
               "The link is invalid or it has expired."

      assert redirected_to(conn) == ~p"/settings_users/log-in"
    end
  end

  describe "DELETE /settings_users/log-out" do
    test "logs the settings_user out", %{conn: conn, settings_user: settings_user} do
      conn = conn |> log_in_settings_user(settings_user) |> delete(~p"/settings_users/log-out")
      assert redirected_to(conn) == ~p"/"
      refute get_session(conn, :settings_user_token)
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "Logged out successfully"
    end

    test "succeeds even if the settings_user is not logged in", %{conn: conn} do
      conn = delete(conn, ~p"/settings_users/log-out")
      assert redirected_to(conn) == ~p"/"
      refute get_session(conn, :settings_user_token)
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "Logged out successfully"
    end
  end
end
