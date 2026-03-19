defmodule AssistantWeb.SettingsUserLive.RegistrationTest do
  use AssistantWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Assistant.AccountsFixtures

  # An admin must exist in the DB or post-registration redirects land on /setup
  setup do
    admin_settings_user_fixture()
    :ok
  end

  describe "Registration page" do
    test "renders registration page", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/settings_users/register")

      assert html =~ "Create Account"
      assert html =~ "Back to Sign In"
    end

    test "redirects if already logged in", %{conn: conn} do
      result =
        conn
        |> log_in_settings_user(settings_user_fixture())
        |> live(~p"/settings_users/register")
        |> follow_redirect(conn, ~p"/workspace")

      assert {:ok, _conn} = result
    end

    test "renders errors for invalid data", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/settings_users/register")

      result =
        lv
        |> element("#registration_form")
        |> render_change(settings_user: %{"email" => "with spaces"})

      assert result =~ "Create Account"
      assert result =~ "must have the @ sign and no spaces"
    end
  end

  describe "register settings_user" do
    test "creates account but does not log in", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/settings_users/register")

      email = unique_settings_user_email()

      form =
        form(lv, "#registration_form",
          settings_user: valid_settings_user_attributes(email: email)
        )

      {:ok, _lv, html} =
        render_submit(form)
        |> follow_redirect(conn, ~p"/settings_users/log-in")

      assert html =~
               ~r/An email was sent to .*, please access it to confirm your account/
    end

    test "renders errors for duplicated email", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/settings_users/register")

      settings_user = settings_user_fixture(%{email: "test@email.com"})

      result =
        lv
        |> form("#registration_form",
          settings_user: %{"email" => settings_user.email}
        )
        |> render_submit()

      # PetalComponents renders the unique constraint error — the form shows an error state
      assert result =~ "pc-form-field-wrapper--error"
    end
  end

  describe "registration navigation" do
    test "redirects to login page when the Back to Sign In link is clicked", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/settings_users/register")

      {:ok, _login_live, login_html} =
        lv
        |> element(~s|a[href="/settings_users/log-in"]|, "Back to Sign In")
        |> render_click()
        |> follow_redirect(conn, ~p"/settings_users/log-in")

      assert login_html =~ "Sign In"
    end
  end
end
