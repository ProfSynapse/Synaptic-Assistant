defmodule AssistantWeb.SettingsUserLive.SettingsTest do
  use AssistantWeb.ConnCase, async: true

  alias Assistant.Accounts
  import Phoenix.LiveViewTest
  import Assistant.AccountsFixtures

  describe "Settings page" do
    test "renders settings page", %{conn: conn} do
      {:ok, _lv, html} =
        conn
        |> log_in_settings_user(settings_user_fixture())
        |> live(~p"/settings_users/settings")

      assert html =~ "Change Email"
      assert html =~ "Save Password"
    end

    test "redirects if settings_user is not logged in", %{conn: conn} do
      assert {:error, redirect} = live(conn, ~p"/settings_users/settings")

      assert {:redirect, %{to: path, flash: flash}} = redirect
      assert path == ~p"/settings_users/log-in"
      assert %{"error" => "You must log in to access this page."} = flash
    end

    test "redirects if settings_user is not in sudo mode", %{conn: conn} do
      {:ok, conn} =
        conn
        |> log_in_settings_user(settings_user_fixture(),
          token_authenticated_at: DateTime.add(DateTime.utc_now(:second), -11, :minute)
        )
        |> live(~p"/settings_users/settings")
        |> follow_redirect(conn, ~p"/settings_users/log-in")

      assert conn.resp_body =~ "You must re-authenticate to access this page."
    end
  end

  describe "update email form" do
    setup %{conn: conn} do
      settings_user = settings_user_fixture()
      %{conn: log_in_settings_user(conn, settings_user), settings_user: settings_user}
    end

    test "updates the settings_user email", %{conn: conn, settings_user: settings_user} do
      new_email = unique_settings_user_email()

      {:ok, lv, _html} = live(conn, ~p"/settings_users/settings")

      result =
        lv
        |> form("#email_form", %{
          "settings_user" => %{"email" => new_email}
        })
        |> render_submit()

      assert result =~ "A link to confirm your email"
      assert Accounts.get_settings_user_by_email(settings_user.email)
    end

    test "renders errors with invalid data (phx-change)", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/settings_users/settings")

      result =
        lv
        |> element("#email_form")
        |> render_change(%{
          "action" => "update_email",
          "settings_user" => %{"email" => "with spaces"}
        })

      assert result =~ "Change Email"
      assert result =~ "must have the @ sign and no spaces"
    end

    test "renders errors with invalid data (phx-submit)", %{
      conn: conn,
      settings_user: settings_user
    } do
      {:ok, lv, _html} = live(conn, ~p"/settings_users/settings")

      result =
        lv
        |> form("#email_form", %{
          "settings_user" => %{"email" => settings_user.email}
        })
        |> render_submit()

      assert result =~ "Change Email"
      assert result =~ "did not change"
    end
  end

  describe "update password form" do
    setup %{conn: conn} do
      settings_user = settings_user_fixture()
      %{conn: log_in_settings_user(conn, settings_user), settings_user: settings_user}
    end

    test "updates the settings_user password", %{conn: conn, settings_user: settings_user} do
      new_password = valid_settings_user_password()

      {:ok, lv, _html} = live(conn, ~p"/settings_users/settings")

      form =
        form(lv, "#password_form", %{
          "settings_user" => %{
            "email" => settings_user.email,
            "password" => new_password,
            "password_confirmation" => new_password
          }
        })

      render_submit(form)

      new_password_conn = follow_trigger_action(form, conn)

      assert redirected_to(new_password_conn) == ~p"/settings_users/settings"

      assert get_session(new_password_conn, :settings_user_token) !=
               get_session(conn, :settings_user_token)

      assert Phoenix.Flash.get(new_password_conn.assigns.flash, :info) =~
               "Password updated successfully"

      assert Accounts.get_settings_user_by_email_and_password(settings_user.email, new_password)
    end

    test "renders errors with invalid data (phx-change)", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/settings_users/settings")

      result =
        lv
        |> element("#password_form")
        |> render_change(%{
          "settings_user" => %{
            "password" => "too short",
            "password_confirmation" => "does not match"
          }
        })

      assert result =~ "Save Password"
      assert result =~ "should be at least 12 character(s)"
      assert result =~ "does not match password"
    end

    test "renders errors with invalid data (phx-submit)", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/settings_users/settings")

      result =
        lv
        |> form("#password_form", %{
          "settings_user" => %{
            "password" => "too short",
            "password_confirmation" => "does not match"
          }
        })
        |> render_submit()

      assert result =~ "Save Password"
      assert result =~ "should be at least 12 character(s)"
      assert result =~ "does not match password"
    end
  end

  describe "confirm email" do
    setup %{conn: conn} do
      settings_user = settings_user_fixture()
      email = unique_settings_user_email()

      token =
        extract_settings_user_token(fn url ->
          Accounts.deliver_settings_user_update_email_instructions(
            %{settings_user | email: email},
            settings_user.email,
            url
          )
        end)

      %{
        conn: log_in_settings_user(conn, settings_user),
        token: token,
        email: email,
        settings_user: settings_user
      }
    end

    test "updates the settings_user email once", %{
      conn: conn,
      settings_user: settings_user,
      token: token,
      email: email
    } do
      {:error, redirect} = live(conn, ~p"/settings_users/settings/confirm-email/#{token}")

      assert {:live_redirect, %{to: path, flash: flash}} = redirect
      assert path == ~p"/settings_users/settings"
      assert %{"info" => message} = flash
      assert message == "Email changed successfully."
      refute Accounts.get_settings_user_by_email(settings_user.email)
      assert Accounts.get_settings_user_by_email(email)

      # use confirm token again
      {:error, redirect} = live(conn, ~p"/settings_users/settings/confirm-email/#{token}")
      assert {:live_redirect, %{to: path, flash: flash}} = redirect
      assert path == ~p"/settings_users/settings"
      assert %{"error" => message} = flash
      assert message == "Email change link is invalid or it has expired."
    end

    test "does not update email with invalid token", %{conn: conn, settings_user: settings_user} do
      {:error, redirect} = live(conn, ~p"/settings_users/settings/confirm-email/oops")
      assert {:live_redirect, %{to: path, flash: flash}} = redirect
      assert path == ~p"/settings_users/settings"
      assert %{"error" => message} = flash
      assert message == "Email change link is invalid or it has expired."
      assert Accounts.get_settings_user_by_email(settings_user.email)
    end

    test "redirects if settings_user is not logged in", %{token: token} do
      conn = build_conn()
      {:error, redirect} = live(conn, ~p"/settings_users/settings/confirm-email/#{token}")
      assert {:redirect, %{to: path, flash: flash}} = redirect
      assert path == ~p"/settings_users/log-in"
      assert %{"error" => message} = flash
      assert message == "You must log in to access this page."
    end
  end
end
