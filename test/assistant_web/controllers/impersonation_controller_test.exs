defmodule AssistantWeb.ImpersonationControllerTest do
  use AssistantWeb.ConnCase, async: false

  import Assistant.AccountsFixtures

  alias Assistant.Accounts
  alias Assistant.Accounts.SettingsUser

  setup %{conn: conn} do
    admin = settings_user_fixture()
    {:ok, admin} = Accounts.bootstrap_admin_access(admin)
    conn = log_in_settings_user(conn, admin)

    %{conn: conn, admin: admin}
  end

  defp create_target_user(attrs \\ %{}) do
    email = attrs[:email] || unique_settings_user_email()
    attrs = Map.put(attrs, :email, email)

    Accounts.upsert_settings_user_allowlist_entry(
      %{email: email, active: true, is_admin: false, scopes: []},
      nil,
      transaction?: false
    )

    settings_user_fixture(attrs)
  end

  describe "POST /settings_users/impersonate" do
    test "admin can impersonate another user", %{conn: conn} do
      target = create_target_user(%{email: "target@example.com"})

      conn = post(conn, ~p"/settings_users/impersonate", %{"id" => target.id})

      assert redirected_to(conn) == ~p"/settings"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "target@example.com"
    end

    test "admin cannot impersonate themselves", %{conn: conn, admin: admin} do
      conn = post(conn, ~p"/settings_users/impersonate", %{"id" => admin.id})

      assert redirected_to(conn) == ~p"/settings/admin"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "cannot impersonate yourself"
    end

    test "admin cannot impersonate a disabled user", %{conn: conn} do
      target = create_target_user(%{email: "disabled@example.com"})

      target
      |> SettingsUser.disabled_changeset(DateTime.utc_now(:second))
      |> Assistant.Repo.update!()

      conn = post(conn, ~p"/settings_users/impersonate", %{"id" => target.id})

      assert redirected_to(conn) == ~p"/settings/admin"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "disabled"
    end

    test "admin cannot impersonate a nonexistent user", %{conn: conn} do
      conn =
        post(conn, ~p"/settings_users/impersonate", %{
          "id" => Ecto.UUID.generate()
        })

      assert redirected_to(conn) == ~p"/settings/admin"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "not found"
    end

    test "non-admin cannot impersonate", %{conn: _conn} do
      non_admin = create_target_user(%{email: "nonadmin@example.com"})
      target = create_target_user(%{email: "victim@example.com"})

      conn =
        build_conn()
        |> log_in_settings_user(non_admin)
        |> post(~p"/settings_users/impersonate", %{"id" => target.id})

      assert redirected_to(conn) == ~p"/settings"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Not authorized"
    end

    test "impersonation sets admin_impersonator_token in session", %{conn: conn} do
      target = create_target_user(%{email: "session-test@example.com"})

      conn = post(conn, ~p"/settings_users/impersonate", %{"id" => target.id})

      # Follow the redirect and check the session has impersonation token
      assert get_session(conn, :admin_impersonator_token) != nil
    end
  end

  describe "DELETE /settings_users/impersonate" do
    test "admin can stop impersonating and return to their session", %{conn: conn, admin: admin} do
      target = create_target_user(%{email: "stop-test@example.com"})

      # Start impersonation
      conn = post(conn, ~p"/settings_users/impersonate", %{"id" => target.id})

      # Stop impersonation
      conn = delete(conn, ~p"/settings_users/impersonate")

      assert redirected_to(conn) == ~p"/settings/admin"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "Returned to your admin account"

      # The admin token should now be the main session token
      assert get_session(conn, :admin_impersonator_token) == nil
    end

    test "returns error when not impersonating", %{conn: conn} do
      conn = delete(conn, ~p"/settings_users/impersonate")

      assert redirected_to(conn) == ~p"/settings"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Not currently impersonating"
    end
  end
end
