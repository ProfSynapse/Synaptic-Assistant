defmodule AssistantWeb.SettingsUserLive.LoginTest do
  use AssistantWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Assistant.AccountsFixtures

  # An admin must exist in the DB or the login page redirects to /setup
  setup do
    admin_settings_user_fixture()
    :ok
  end

  setup do
    previous = Application.get_env(:assistant, :deployment_mode, :cloud)

    on_exit(fn ->
      Application.put_env(:assistant, :deployment_mode, previous)
    end)

    :ok
  end

  describe "login page" do
    test "renders login page", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/settings_users/log-in")

      assert html =~ "Sign In"
      assert html =~ "Sign in with Google"
      assert html =~ "Create Account"
      assert html =~ "Send Magic Link"
    end

    test "hides email self-serve links in self-hosted mode", %{conn: conn} do
      Application.put_env(:assistant, :deployment_mode, :self_hosted)

      {:ok, _lv, html} = live(conn, ~p"/settings_users/log-in")

      assert html =~ "Sign In"
      refute html =~ "Sign in with Google"
      refute html =~ "Create Account"
      refute html =~ "Send Magic Link"
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

    test "redirects magic-link page back to password login in self-hosted mode", %{conn: conn} do
      Application.put_env(:assistant, :deployment_mode, :self_hosted)

      assert {:ok, _lv, _html} = live(conn, ~p"/settings_users/log-in")

      result =
        live(conn, ~p"/settings_users/magic-link")
        |> follow_redirect(conn, ~p"/settings_users/log-in")

      assert {:ok, _lv, html} = result
      assert html =~ "Sign In"
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

      assert redirected_to(conn) == ~p"/workspace"
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
    test "redirects to registration page when Create Account is clicked", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/settings_users/log-in")

      {:ok, _login_live, login_html} =
        lv
        |> element(~s|a[href="/settings_users/register"]|, "Create Account")
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

      assert html =~ "Sign in with Google"
      assert html =~ ~s(id="login_form_password_email")
      assert html =~ ~s(value="#{settings_user.email}")
      # Email field is readonly when re-authenticating
      assert html =~ "readonly"
    end

    test "hides Google sign in during self-hosted re-authentication", %{
      conn: conn,
      settings_user: _settings_user
    } do
      Application.put_env(:assistant, :deployment_mode, :self_hosted)

      {:ok, _lv, html} = live(conn, ~p"/settings_users/log-in")

      refute html =~ "Sign in with Google"
      refute html =~ "Create Account"
      refute html =~ "Send Magic Link"
    end
  end
end
