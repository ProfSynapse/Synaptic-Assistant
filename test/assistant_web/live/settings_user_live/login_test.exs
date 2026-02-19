defmodule AssistantWeb.SettingsUserLive.LoginTest do
  use AssistantWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Assistant.AccountsFixtures

  describe "login page" do
    test "renders login page", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/settings_users/log-in")

      assert html =~ "Sign In"
      assert html =~ "Sign in with Google"
      assert html =~ "Create account"
      assert html =~ "Use magic link"
    end
  end

  describe "settings_user login - magic link" do
    test "sends magic link email when settings_user exists", %{conn: conn} do
      settings_user = settings_user_fixture()

      {:ok, lv, _html} = live(conn, ~p"/settings_users/magic-link")

      {:ok, _lv, html} =
        form(lv, "#login_form_magic", settings_user: %{email: settings_user.email})
        |> render_submit()
        |> follow_redirect(conn, ~p"/settings_users/log-in")

      assert html =~ "If your email is in our system"

      assert Assistant.Repo.get_by!(Assistant.Accounts.SettingsUserToken,
               settings_user_id: settings_user.id
             ).context ==
               "login"
    end

    test "does not disclose if settings_user is registered", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/settings_users/magic-link")

      {:ok, _lv, html} =
        form(lv, "#login_form_magic", settings_user: %{email: "idonotexist@example.com"})
        |> render_submit()
        |> follow_redirect(conn, ~p"/settings_users/log-in")

      assert html =~ "If your email is in our system"
    end
  end

  describe "settings_user login - password" do
    test "redirects if settings_user logs in with valid credentials", %{conn: conn} do
      settings_user = settings_user_fixture() |> set_password()

      {:ok, lv, _html} = live(conn, ~p"/settings_users/log-in")

      form =
        form(lv, "#login_form_password",
          settings_user: %{
            email: settings_user.email,
            password: valid_settings_user_password(),
            remember_me: true
          }
        )

      conn = submit_form(form, conn)

      assert redirected_to(conn) == ~p"/"
    end

    test "redirects to login page with a flash error if credentials are invalid", %{
      conn: conn
    } do
      {:ok, lv, _html} = live(conn, ~p"/settings_users/log-in")

      form =
        form(lv, "#login_form_password",
          settings_user: %{email: "test@email.com", password: "123456"}
        )

      render_submit(form, %{user: %{remember_me: true}})

      conn = follow_trigger_action(form, conn)
      assert Phoenix.Flash.get(conn.assigns.flash, :error) == "Invalid email or password"
      assert redirected_to(conn) == ~p"/settings_users/log-in"
    end
  end

  describe "login navigation" do
    test "redirects to registration page when Create account is clicked", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/settings_users/log-in")

      {:ok, _login_live, login_html} =
        lv
        |> element("main a", "Create account")
        |> render_click()
        |> follow_redirect(conn, ~p"/settings_users/register")

      assert login_html =~ "Create Account"
    end
  end

  describe "re-authentication (sudo mode)" do
    setup %{conn: conn} do
      settings_user = settings_user_fixture()
      %{settings_user: settings_user, conn: log_in_settings_user(conn, settings_user)}
    end

    test "shows login page with email filled in", %{conn: conn, settings_user: settings_user} do
      {:ok, _lv, html} = live(conn, ~p"/settings_users/log-in")

      assert html =~ "Reauthenticate to continue with sensitive account changes."
      assert html =~ "Sign in with Google"

      assert html =~ ~s(id="login_form_password_email")
      assert html =~ ~s(value="#{settings_user.email}")
    end
  end
end
