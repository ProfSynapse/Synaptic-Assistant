defmodule AssistantWeb.SettingsLive.AdminAccessOnboardingTest do
  use AssistantWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Assistant.AccountsFixtures

  alias Assistant.Accounts
  alias Assistant.Accounts.SettingsUser
  alias Assistant.IntegrationSettings
  alias Assistant.Repo

  # ─────────────────────────────────────────────────
  # Helpers
  # ─────────────────────────────────────────────────

  defp make_admin(settings_user) do
    {:ok, admin} = Accounts.bootstrap_admin_access(settings_user)
    admin
  end

  defp set_billing_role(settings_user, role) do
    settings_user
    |> Ecto.Changeset.change(billing_role: role)
    |> Repo.update!()
  end

  # ─────────────────────────────────────────────────
  # Route guard: admin section access
  # ─────────────────────────────────────────────────

  describe "admin route guard — bootstrap exception" do
    test "non-admin CAN access admin section when no admins exist (bootstrap available)", %{conn: conn} do
      user = settings_user_fixture()
      conn = log_in_settings_user(conn, user)

      # No admins exist yet, bootstrap should be available
      assert Accounts.admin_bootstrap_available?()

      {:ok, _lv, html} = live(conn, ~p"/settings/admin")

      assert html =~ "Initial Admin Bootstrap"
      assert html =~ "Claim Admin Access"
    end

    test "non-admin BLOCKED from admin section when bootstrap NOT available (admin exists)", %{conn: conn} do
      # Create an admin first to close the bootstrap gate
      admin = settings_user_fixture()
      make_admin(admin)

      # Now create a regular user with member billing_role
      regular = settings_user_fixture()
      conn = log_in_settings_user(conn, regular)

      {:ok, _lv, html} = live(conn, ~p"/settings/admin")

      # Should be redirected to /settings with flash
      assert html =~ "You do not have permission to access admin"
    end
  end

  describe "admin route guard — workspace owner access" do
    setup %{conn: conn} do
      # Create an admin first to close bootstrap gate
      admin = settings_user_fixture()
      make_admin(admin)

      %{conn: conn, admin: admin}
    end

    test "workspace owner (billing_role: owner) CAN access admin section", %{conn: conn} do
      owner = settings_user_fixture() |> set_billing_role("owner")
      conn = log_in_settings_user(conn, owner)

      {:ok, _lv, html} = live(conn, ~p"/settings/admin")

      # Owner should see the Integrations tab
      assert html =~ "Integrations"
    end

    test "workspace admin (billing_role: admin) CAN access admin section", %{conn: conn} do
      billing_admin = settings_user_fixture() |> set_billing_role("admin")
      conn = log_in_settings_user(conn, billing_admin)

      {:ok, _lv, html} = live(conn, ~p"/settings/admin")

      assert html =~ "Integrations"
    end

    test "regular member (billing_role: member) CANNOT access admin section", %{conn: conn} do
      member = settings_user_fixture() |> set_billing_role("member")
      conn = log_in_settings_user(conn, member)

      {:ok, _lv, html} = live(conn, ~p"/settings/admin")

      assert html =~ "You do not have permission to access admin"
    end
  end

  # ─────────────────────────────────────────────────
  # Admin tab gating: workspace owners see only Integrations
  # ─────────────────────────────────────────────────

  describe "admin tab visibility" do
    setup %{conn: conn} do
      admin = settings_user_fixture()
      make_admin(admin)

      %{conn: conn, admin: admin}
    end

    test "admin sees all tabs (Integrations, Models, Users, Policies)", %{conn: conn, admin: admin} do
      conn = log_in_settings_user(conn, admin)
      {:ok, _lv, html} = live(conn, ~p"/settings/admin")

      assert html =~ "Integrations"
      assert html =~ "Models"
      assert html =~ "Users"
      assert html =~ "Policies"
    end

    test "workspace owner sees only Integrations tab", %{conn: conn} do
      owner = settings_user_fixture() |> set_billing_role("owner")
      conn = log_in_settings_user(conn, owner)

      {:ok, _lv, html} = live(conn, ~p"/settings/admin")

      assert html =~ "Integrations"
      # Should NOT see admin-only tabs
      refute html =~ ~r/<button[^>]*>Models<\/button>/
      refute html =~ ~r/<button[^>]*>Users<\/button>/
      refute html =~ ~r/<button[^>]*>Policies<\/button>/
    end

    test "workspace owner cannot switch to models tab", %{conn: conn} do
      owner = settings_user_fixture() |> set_billing_role("owner")
      conn = log_in_settings_user(conn, owner)

      {:ok, lv, _html} = live(conn, ~p"/settings/admin")

      # Even if they somehow try to switch to models tab, the content is gated
      html = render_click(lv, "switch_admin_tab", %{"tab" => "models"})

      # Models content is gated by `@current_scope.admin?`
      refute html =~ "Model Providers"
      refute html =~ "Role Defaults"
    end

    test "workspace owner cannot switch to users tab", %{conn: conn} do
      owner = settings_user_fixture() |> set_billing_role("owner")
      conn = log_in_settings_user(conn, owner)

      {:ok, lv, _html} = live(conn, ~p"/settings/admin")
      html = render_click(lv, "switch_admin_tab", %{"tab" => "users"})

      refute html =~ "User Management"
    end
  end

  # ─────────────────────────────────────────────────
  # Nav items: Admin tab visibility in sidebar
  # ─────────────────────────────────────────────────

  describe "sidebar nav visibility" do
    setup %{conn: conn} do
      admin = settings_user_fixture()
      make_admin(admin)

      %{conn: conn, admin: admin}
    end

    test "admin sees Admin nav item", %{conn: conn, admin: admin} do
      conn = log_in_settings_user(conn, admin)
      {:ok, _lv, html} = live(conn, ~p"/settings")

      assert html =~ "Admin"
    end

    test "workspace owner sees Admin nav item", %{conn: conn} do
      owner = settings_user_fixture() |> set_billing_role("owner")
      conn = log_in_settings_user(conn, owner)

      {:ok, _lv, html} = live(conn, ~p"/settings")

      assert html =~ "Admin"
    end

    test "regular member does NOT see Admin nav item", %{conn: conn} do
      member = settings_user_fixture() |> set_billing_role("member")
      conn = log_in_settings_user(conn, member)

      {:ok, _lv, html} = live(conn, ~p"/settings")

      # The sidebar renders admin as a link with href /settings/admin
      refute html =~ ~s|href="/settings/admin"|
    end
  end

  # ─────────────────────────────────────────────────
  # Bootstrap claim flow
  # ─────────────────────────────────────────────────

  describe "bootstrap claim" do
    test "bootstrap claim creates allowlist entry and grants admin", %{conn: conn} do
      user = settings_user_fixture()
      conn = log_in_settings_user(conn, user)

      assert Accounts.admin_bootstrap_available?()

      {:ok, lv, _html} = live(conn, ~p"/settings/admin")
      html = render_click(lv, "claim_bootstrap_admin", %{})

      assert html =~ "Admin access claimed"

      # Verify user is now admin
      updated_user = Repo.get!(SettingsUser, user.id)
      assert updated_user.is_admin == true

      # Bootstrap should now be closed
      refute Accounts.admin_bootstrap_available?()
    end

    test "second user bootstrap claim fails gracefully", %{conn: conn} do
      # First user claims admin
      first = settings_user_fixture()
      make_admin(first)

      # Second user tries — bootstrap gate is now closed
      second = settings_user_fixture()
      conn = log_in_settings_user(conn, second)

      # Second user can't even access admin section now (redirected)
      {:ok, _lv, html} = live(conn, ~p"/settings/admin")
      assert html =~ "You do not have permission to access admin"
    end
  end

  # ─────────────────────────────────────────────────
  # Onboarding checklist
  # ─────────────────────────────────────────────────

  describe "onboarding checklist" do
    test "checklist shows on profile for new non-admin user", %{conn: conn} do
      user = settings_user_fixture()
      conn = log_in_settings_user(conn, user)

      {:ok, _lv, html} = live(conn, ~p"/settings")

      assert html =~ "Getting Started"
      assert html =~ "Claim admin access"
      assert html =~ "Connect an LLM provider"
      assert html =~ "Connect a messaging channel"
    end

    test "checklist hides when dismissed", %{conn: conn} do
      user = settings_user_fixture()
      conn = log_in_settings_user(conn, user)

      {:ok, lv, _html} = live(conn, ~p"/settings")

      # Dismiss the checklist
      html = render_click(lv, "dismiss_onboarding", %{})

      refute html =~ "Getting Started"

      # Verify onboarding_dismissed_at is set in DB
      updated_user = Repo.get!(SettingsUser, user.id)
      assert updated_user.onboarding_dismissed_at != nil
    end

    test "checklist stays hidden after dismiss on page reload", %{conn: conn} do
      user = settings_user_fixture()
      now = DateTime.utc_now(:second)
      {:ok, _} = Accounts.update_settings_user_onboarding_dismissed(user, now)

      conn = log_in_settings_user(conn, user)
      {:ok, _lv, html} = live(conn, ~p"/settings")

      refute html =~ "Getting Started"
    end

    test "claim admin marks checklist item as complete", %{conn: conn} do
      user = settings_user_fixture()
      conn = log_in_settings_user(conn, user)

      {:ok, _lv, html} = live(conn, ~p"/settings")

      # Before claiming, admin item should be incomplete — shows action link, no "Done"
      assert html =~ "Claim admin access"
      assert html =~ "Go to Admin"

      # Navigate to admin and claim
      {:ok, lv, _html} = live(conn, ~p"/settings/admin")
      render_click(lv, "claim_bootstrap_admin", %{})

      # Navigate back to profile to check checklist
      {:ok, _lv, html} = live(conn, ~p"/settings")

      # The admin item should now show as complete with "Done" status and check icon
      assert html =~ "Claim admin access"
      assert html =~ "sa-onboarding-done"
      assert html =~ "Done"
      assert html =~ "hero-check-circle"
    end

    test "checklist shows LLM item as complete when user has openrouter key", %{conn: conn} do
      user = settings_user_fixture()

      user
      |> Ecto.Changeset.change(%{openrouter_api_key: "sk-or-test-key"})
      |> Repo.update!()

      conn = log_in_settings_user(conn, user)
      {:ok, _lv, html} = live(conn, ~p"/settings")

      assert html =~ "Getting Started"
      # LLM item should show as complete
      assert html =~ "Connect an LLM provider"
      assert html =~ "Done"
    end

    test "checklist shows channel item as complete when a channel is configured", %{conn: conn} do
      user = settings_user_fixture()
      {:ok, _} = IntegrationSettings.put(:telegram_bot_token, "test-bot-token-123")

      conn = log_in_settings_user(conn, user)
      {:ok, _lv, html} = live(conn, ~p"/settings")

      assert html =~ "Getting Started"
      # Channel item should show as complete
      assert html =~ "Connect a messaging channel"
      assert html =~ "Done"
    end

    test "checklist auto-hides when all items are complete", %{conn: conn} do
      user = settings_user_fixture()

      # Complete admin: claim bootstrap
      make_admin(user)

      # Complete LLM: set openrouter key
      user =
        user
        |> Ecto.Changeset.change(%{openrouter_api_key: "sk-or-test-key"})
        |> Repo.update!()

      # Complete channel: configure telegram
      {:ok, _} = IntegrationSettings.put(:telegram_bot_token, "test-bot-token-123")

      conn = log_in_settings_user(conn, user)
      {:ok, _lv, html} = live(conn, ~p"/settings")

      # Checklist should NOT render when all items are complete
      refute html =~ "Getting Started"
      refute html =~ "sa-onboarding-card"
    end
  end

  # ─────────────────────────────────────────────────
  # Load admin data split: full admin vs workspace owner
  # ─────────────────────────────────────────────────

  describe "admin data loading" do
    setup %{conn: conn} do
      admin = settings_user_fixture()
      make_admin(admin)

      %{conn: conn, admin: admin}
    end

    test "admin gets full admin data including user management", %{conn: conn, admin: admin} do
      conn = log_in_settings_user(conn, admin)
      {:ok, lv, _html} = live(conn, ~p"/settings/admin")

      # Switch to users tab to verify user data was loaded
      html = render_click(lv, "switch_admin_tab", %{"tab" => "users"})
      assert html =~ "User Management"
      assert html =~ admin.email
    end

    test "workspace owner gets integration settings but not user data", %{conn: conn} do
      owner = settings_user_fixture() |> set_billing_role("owner")
      conn = log_in_settings_user(conn, owner)

      {:ok, _lv, html} = live(conn, ~p"/settings/admin")

      # Owner should see integrations
      assert html =~ "Integrations"

      # But no user management (tab not even rendered)
      refute html =~ "User Management"
    end
  end
end
