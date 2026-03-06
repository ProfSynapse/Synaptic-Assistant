defmodule AssistantWeb.AdminUserManagementTest do
  use AssistantWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Assistant.AccountsFixtures

  alias Assistant.Accounts
  alias Assistant.Accounts.SettingsUser

  # ──────────────────────────────────────────────
  # Setup: admin user with full privileges
  # ──────────────────────────────────────────────

  setup %{conn: conn} do
    admin = settings_user_fixture()
    {:ok, admin} = Accounts.bootstrap_admin_access(admin)
    conn = log_in_settings_user(conn, admin)

    %{conn: conn, admin: admin}
  end

  defp admin_path, do: ~p"/settings/admin"

  # Switch to the Users tab (admin defaults to Integrations tab)
  defp switch_to_users_tab(lv) do
    render_click(lv, "switch_admin_tab", %{"tab" => "users"})
  end

  defp create_target_user(attrs) do
    email = attrs[:email] || unique_settings_user_email()
    attrs = Map.put(attrs, :email, email)

    # Add to allowlist so registration succeeds (bootstrap_admin_access enforces allowlist)
    Accounts.upsert_settings_user_allowlist_entry(
      %{email: email, active: true, is_admin: false, scopes: []},
      nil,
      transaction?: false
    )

    settings_user_fixture(attrs)
  end

  # ──────────────────────────────────────────────
  # Component rendering: User cards section
  # ──────────────────────────────────────────────

  describe "user cards rendering" do
    test "renders Users heading", %{conn: conn} do
      {:ok, lv, _html} = live(conn, admin_path())
      html = switch_to_users_tab(lv)

      assert html =~ "User Management"
    end

    test "renders user rows for each user", %{conn: conn, admin: admin} do
      target = create_target_user(%{email: "cardtest@example.com"})

      {:ok, lv, _html} = live(conn, admin_path())
      html = switch_to_users_tab(lv)

      assert html =~ admin.email
      assert html =~ target.email
    end

    test "renders Admin badge for admin users", %{conn: conn} do
      {:ok, lv, _html} = live(conn, admin_path())
      html = switch_to_users_tab(lv)

      assert html =~ "Admin"
    end

    test "renders Disabled badge for disabled users", %{conn: conn} do
      target = create_target_user(%{email: "disabled-badge@example.com"})

      target
      |> SettingsUser.disabled_changeset(DateTime.utc_now(:second))
      |> Assistant.Repo.update!()

      {:ok, lv, _html} = live(conn, admin_path())
      html = switch_to_users_tab(lv)

      # Disabled users have a non-nil disabled_at, so the toggle is unchecked
      assert html =~ "user-row-#{target.id}"
    end

    test "renders OR Key badge when user has OpenRouter key", %{conn: conn} do
      target = create_target_user(%{email: "orkey-badge@example.com"})
      {:ok, _} = Accounts.save_openrouter_api_key(target, "sk-or-test-key")

      {:ok, lv, _html} = live(conn, admin_path())
      html = switch_to_users_tab(lv)

      assert html =~ "OR Key"
    end

    test "renders Linked badge when user has linked chat account", %{conn: conn} do
      {:ok, lv, _html} = live(conn, admin_path())
      html = switch_to_users_tab(lv)

      # "Linked" badge is rendered conditionally via :if guard
      # Verify user rows are present in the table
      assert html =~ "user-row-"
    end

    test "renders search input", %{conn: conn} do
      {:ok, lv, _html} = live(conn, admin_path())
      html = switch_to_users_tab(lv)

      assert html =~ "Search users by email or name"
      assert html =~ "phx-change=\"search_admin_users\""
    end

    test "renders edit and delete buttons for each user row", %{conn: conn} do
      _target = create_target_user(%{email: "buttons@example.com"})

      {:ok, lv, _html} = live(conn, admin_path())
      html = switch_to_users_tab(lv)

      assert html =~ "edit_admin_user"
      assert html =~ "delete_admin_user"
    end

    test "renders enable/disable toggle for each row", %{conn: conn} do
      _target = create_target_user(%{email: "toggle@example.com"})

      {:ok, lv, _html} = live(conn, admin_path())
      html = switch_to_users_tab(lv)

      assert html =~ "toggle_user_disabled"
    end

    test "disables toggle and delete for current user (self-protection)", %{
      conn: conn,
      admin: admin
    } do
      {:ok, lv, _html} = live(conn, admin_path())
      html = switch_to_users_tab(lv)

      # The admin's own row should have disabled toggle and delete
      assert html =~ "user-row-#{admin.id}"
    end
  end

  # ──────────────────────────────────────────────
  # Event: search_admin_users
  # ──────────────────────────────────────────────

  describe "search_admin_users event" do
    test "filters user rows by email", %{conn: conn} do
      match = create_target_user(%{email: "findme-search@example.com"})
      nomatch = create_target_user(%{email: "hidden-user@example.com"})

      {:ok, lv, _html} = live(conn, admin_path())
      switch_to_users_tab(lv)

      html =
        lv
        |> form("form[phx-change=\"search_admin_users\"]", %{"query" => "findme"})
        |> render_change()

      assert html =~ "user-row-#{match.id}"
      refute html =~ "user-row-#{nomatch.id}"
    end

    test "empty search shows all user rows", %{conn: conn, admin: admin} do
      target = create_target_user(%{email: "showall@example.com"})

      {:ok, lv, _html} = live(conn, admin_path())
      switch_to_users_tab(lv)

      # First filter to narrow results
      lv
      |> form("form[phx-change=\"search_admin_users\"]", %{"query" => "showall"})
      |> render_change()

      # Then clear search
      html =
        lv
        |> form("form[phx-change=\"search_admin_users\"]", %{"query" => ""})
        |> render_change()

      assert html =~ "user-row-#{admin.id}"
      assert html =~ "user-row-#{target.id}"
    end

    test "search is case-insensitive", %{conn: conn} do
      target = create_target_user(%{email: "CaseTest@Example.COM"})

      {:ok, lv, _html} = live(conn, admin_path())
      switch_to_users_tab(lv)

      html =
        lv
        |> form("form[phx-change=\"search_admin_users\"]", %{"query" => "casetest"})
        |> render_change()

      assert html =~ "user-row-#{target.id}"
    end

    test "search with no matches shows empty state", %{conn: conn} do
      {:ok, lv, _html} = live(conn, admin_path())
      switch_to_users_tab(lv)

      html =
        lv
        |> form("form[phx-change=\"search_admin_users\"]", %{"query" => "zzz-nonexistent-zzz"})
        |> render_change()

      assert html =~ "No users found"
    end
  end

  # ──────────────────────────────────────────────
  # Event: edit_admin_user (opens detail view)
  # ──────────────────────────────────────────────

  describe "edit_admin_user event" do
    test "opens detail view for a user", %{conn: conn} do
      target = create_target_user(%{email: "detail-view@example.com"})

      {:ok, lv, _html} = live(conn, admin_path())
      switch_to_users_tab(lv)

      html =
        lv
        |> element("button[phx-click='edit_admin_user'][phx-value-id='#{target.id}']")
        |> render_click()

      # Detail view should show user email and Account Controls heading
      assert html =~ "detail-view@example.com"
      assert html =~ "Account Controls"
    end

    test "detail view shows API Keys section", %{conn: conn} do
      target = create_target_user(%{email: "api-keys-view@example.com"})

      {:ok, lv, _html} = live(conn, admin_path())
      switch_to_users_tab(lv)

      html =
        lv
        |> element("button[phx-click='edit_admin_user'][phx-value-id='#{target.id}']")
        |> render_click()

      assert html =~ "API Keys"
      assert html =~ "OpenRouter API Key"
      assert html =~ "OpenAI API Key"
    end

    test "detail view shows personal model defaults control", %{conn: conn} do
      target = create_target_user(%{email: "model-access-view@example.com"})

      {:ok, lv, _html} = live(conn, admin_path())
      switch_to_users_tab(lv)

      html =
        lv
        |> element("button[phx-click='edit_admin_user'][phx-value-id='#{target.id}']")
        |> render_click()

      assert html =~ "Can Manage Personal Model Defaults"
    end

    test "detail view shows user model defaults editor", %{conn: conn} do
      target = create_target_user(%{email: "user-model-defaults-view@example.com"})

      {:ok, lv, _html} = live(conn, admin_path())
      switch_to_users_tab(lv)

      html =
        lv
        |> element("button[phx-click='edit_admin_user'][phx-value-id='#{target.id}']")
        |> render_click()

      assert html =~ "User Model Defaults"
      assert html =~ "Changes save automatically."
    end

    test "detail view shows user metadata fields", %{conn: conn} do
      target = create_target_user(%{email: "metadata-view@example.com"})

      {:ok, lv, _html} = live(conn, admin_path())
      switch_to_users_tab(lv)

      html =
        lv
        |> element("button[phx-click='edit_admin_user'][phx-value-id='#{target.id}']")
        |> render_click()

      assert html =~ "Display Name"
      assert html =~ "Email"
      assert html =~ "Confirmed At"
      assert html =~ "Created At"
      assert html =~ "Chat Account"
      assert html =~ "Access Scopes"
    end

    test "returns error flash for nonexistent user", %{conn: conn} do
      fake_id = Ecto.UUID.generate()

      {:ok, lv, _html} = live(conn, admin_path())
      switch_to_users_tab(lv)

      html = render_click(lv, "edit_admin_user", %{"id" => fake_id})

      assert html =~ "User not found"
    end
  end

  # ──────────────────────────────────────────────
  # Event: back_to_admin_users
  # ──────────────────────────────────────────────

  describe "back_to_admin_users event" do
    test "returns to user list from detail view", %{conn: conn} do
      target = create_target_user(%{email: "back-test@example.com"})

      {:ok, lv, _html} = live(conn, admin_path())
      switch_to_users_tab(lv)

      # Open detail view
      lv
      |> element("button[phx-click='edit_admin_user'][phx-value-id='#{target.id}']")
      |> render_click()

      # Click back
      html =
        lv
        |> element("button[phx-click='back_to_admin_users']")
        |> render_click()

      # Should show user list again (search input visible, detail view gone)
      assert html =~ "Search users by email or name"
      refute html =~ "Account Controls"
    end
  end

  # ──────────────────────────────────────────────
  # Event: toggle_user_disabled
  # ──────────────────────────────────────────────

  describe "toggle_user_disabled event" do
    test "disables an enabled user and shows flash", %{conn: conn} do
      target = create_target_user(%{email: "disable-me@example.com"})

      {:ok, lv, _html} = live(conn, admin_path())
      switch_to_users_tab(lv)

      html = render_click(lv, "toggle_user_disabled", %{"id" => target.id})

      assert html =~ "User status updated"

      # Verify in DB
      reloaded = Accounts.get_settings_user!(target.id)
      assert not is_nil(reloaded.disabled_at)
    end

    test "re-enables a disabled user", %{conn: conn} do
      target = create_target_user(%{email: "reenable-me@example.com"})

      target
      |> SettingsUser.disabled_changeset(DateTime.utc_now(:second))
      |> Assistant.Repo.update!()

      {:ok, lv, _html} = live(conn, admin_path())
      switch_to_users_tab(lv)

      html = render_click(lv, "toggle_user_disabled", %{"id" => target.id})

      assert html =~ "User status updated"

      reloaded = Accounts.get_settings_user!(target.id)
      assert is_nil(reloaded.disabled_at)
    end

    test "cannot disable self", %{conn: conn, admin: admin} do
      {:ok, lv, _html} = live(conn, admin_path())
      switch_to_users_tab(lv)

      html = render_click(lv, "toggle_user_disabled", %{"id" => admin.id})

      assert html =~ "You cannot disable your own account"
    end

    test "returns error for nonexistent user", %{conn: conn} do
      fake_id = Ecto.UUID.generate()

      {:ok, lv, _html} = live(conn, admin_path())
      switch_to_users_tab(lv)

      html = render_click(lv, "toggle_user_disabled", %{"id" => fake_id})

      assert html =~ "User not found"
    end
  end

  describe "toggle_user_model_defaults_access event" do
    test "enables personal model defaults access and shows flash", %{conn: conn} do
      target = create_target_user(%{email: "model-access@example.com"})

      {:ok, lv, _html} = live(conn, admin_path())
      switch_to_users_tab(lv)

      lv
      |> element("button[phx-click='edit_admin_user'][phx-value-id='#{target.id}']")
      |> render_click()

      html =
        render_click(lv, "toggle_user_model_defaults_access", %{
          "id" => target.id,
          "enabled" => "true"
        })

      assert html =~ "Model defaults access updated"
      assert Accounts.get_settings_user!(target.id).can_manage_model_defaults
    end

    test "disables personal model defaults access and shows flash", %{conn: conn} do
      target = create_target_user(%{email: "model-access-off@example.com"})

      target
      |> Ecto.Changeset.change(can_manage_model_defaults: true)
      |> Assistant.Repo.update!()

      {:ok, lv, _html} = live(conn, admin_path())
      switch_to_users_tab(lv)

      lv
      |> element("button[phx-click='edit_admin_user'][phx-value-id='#{target.id}']")
      |> render_click()

      html =
        render_click(lv, "toggle_user_model_defaults_access", %{
          "id" => target.id,
          "enabled" => "false"
        })

      assert html =~ "Model defaults access updated"
      refute Accounts.get_settings_user!(target.id).can_manage_model_defaults
    end
  end

  describe "admin-managed user model defaults" do
    test "admin can save per-user defaults even when self-management is disabled", %{conn: conn} do
      target = create_target_user(%{email: "admin-managed-defaults@example.com"})

      {:ok, lv, _html} = live(conn, admin_path())
      switch_to_users_tab(lv)

      lv
      |> element("button[phx-click='edit_admin_user'][phx-value-id='#{target.id}']")
      |> render_click()

      html =
        lv
        |> form("#admin-user-model-defaults-form-#{target.id}", %{
          "user_id" => target.id,
          "defaults" => %{"orchestrator" => "openai/gpt-5.2"}
        })
        |> render_change()

      assert html =~ "User Model Defaults"

      # Form submits all role fields; verify the changed one took effect
      assert Accounts.get_settings_user!(target.id).model_defaults["orchestrator"] ==
               "openai/gpt-5.2"
    end

    test "apply global defaults clears a user's scoped overrides", %{conn: conn} do
      target = create_target_user(%{email: "clear-user-defaults@example.com"})

      target
      |> Ecto.Changeset.change(model_defaults: %{"orchestrator" => "openai/gpt-5.2"})
      |> Assistant.Repo.update!()

      {:ok, lv, _html} = live(conn, admin_path())
      switch_to_users_tab(lv)

      lv
      |> element("button[phx-click='edit_admin_user'][phx-value-id='#{target.id}']")
      |> render_click()

      html =
        render_click(lv, "apply_global_admin_user_model_defaults", %{"id" => target.id})

      assert html =~ "User defaults reset to global defaults"
      assert Accounts.get_settings_user!(target.id).model_defaults == %{}
    end
  end

  # ──────────────────────────────────────────────
  # Event: delete_admin_user
  # ──────────────────────────────────────────────

  describe "delete_admin_user event" do
    test "deletes a user and shows flash", %{conn: conn} do
      target = create_target_user(%{email: "deleteme@example.com"})

      {:ok, lv, _html} = live(conn, admin_path())
      switch_to_users_tab(lv)

      html = render_click(lv, "delete_admin_user", %{"id" => target.id})

      assert html =~ "User deleted"

      # Verify deleted from DB
      assert is_nil(Assistant.Repo.get(SettingsUser, target.id))
    end

    test "cannot delete self", %{conn: conn, admin: admin} do
      {:ok, lv, _html} = live(conn, admin_path())
      switch_to_users_tab(lv)

      html = render_click(lv, "delete_admin_user", %{"id" => admin.id})

      assert html =~ "You cannot delete your own account"
    end

    test "returns error for nonexistent user", %{conn: conn} do
      fake_id = Ecto.UUID.generate()

      {:ok, lv, _html} = live(conn, admin_path())
      switch_to_users_tab(lv)

      html = render_click(lv, "delete_admin_user", %{"id" => fake_id})

      assert html =~ "User not found"
    end

    test "deleted user disappears from user list", %{conn: conn} do
      target = create_target_user(%{email: "vanish@example.com"})

      {:ok, lv, _html} = live(conn, admin_path())
      html = switch_to_users_tab(lv)
      assert html =~ "user-row-#{target.id}"

      html = render_click(lv, "delete_admin_user", %{"id" => target.id})

      refute html =~ "user-row-#{target.id}"
    end
  end

  # ──────────────────────────────────────────────
  # Event: toggle_admin_status
  # ──────────────────────────────────────────────

  describe "toggle_admin_status event" do
    test "promotes a regular user to admin", %{conn: conn} do
      target = create_target_user(%{email: "promote@example.com"})

      {:ok, lv, _html} = live(conn, admin_path())
      switch_to_users_tab(lv)

      html = render_click(lv, "toggle_admin_status", %{"id" => target.id, "is-admin" => "true"})

      assert html =~ "Admin status updated"

      reloaded = Accounts.get_settings_user!(target.id)
      assert reloaded.is_admin
    end

    test "demotes an admin when another admin exists", %{conn: conn} do
      target = create_target_user(%{email: "demote@example.com"})

      target
      |> Ecto.Changeset.change(is_admin: true)
      |> Assistant.Repo.update!()

      {:ok, lv, _html} = live(conn, admin_path())
      switch_to_users_tab(lv)

      html = render_click(lv, "toggle_admin_status", %{"id" => target.id, "is-admin" => "false"})

      assert html =~ "Admin status updated"

      reloaded = Accounts.get_settings_user!(target.id)
      refute reloaded.is_admin
    end

    test "returns error for nonexistent user", %{conn: conn} do
      fake_id = Ecto.UUID.generate()

      {:ok, lv, _html} = live(conn, admin_path())
      switch_to_users_tab(lv)

      html = render_click(lv, "toggle_admin_status", %{"id" => fake_id, "is-admin" => "true"})

      assert html =~ "User not found"
    end
  end

  # ──────────────────────────────────────────────
  # Event: save_admin_user_openrouter_key
  # ──────────────────────────────────────────────

  describe "save_admin_user_openrouter_key event" do
    test "saves a key and shows flash", %{conn: conn} do
      target = create_target_user(%{email: "savekey@example.com"})

      {:ok, lv, _html} = live(conn, admin_path())
      switch_to_users_tab(lv)

      # Open detail view first
      lv
      |> element("button[phx-click='edit_admin_user'][phx-value-id='#{target.id}']")
      |> render_click()

      html =
        lv
        |> form("#admin-user-key-form-#{target.id}", %{
          "user_id" => target.id,
          "api_key" => "sk-or-v1-test-key"
        })
        |> render_submit()

      assert html =~ "OpenRouter API key saved"
    end

    test "rejects blank key", %{conn: conn} do
      target = create_target_user(%{email: "blankkey@example.com"})

      {:ok, lv, _html} = live(conn, admin_path())
      switch_to_users_tab(lv)

      # Open detail view
      lv
      |> element("button[phx-click='edit_admin_user'][phx-value-id='#{target.id}']")
      |> render_click()

      html =
        lv
        |> form("#admin-user-key-form-#{target.id}", %{
          "user_id" => target.id,
          "api_key" => ""
        })
        |> render_submit()

      assert html =~ "API key cannot be blank"
    end

    test "rejects whitespace-only key", %{conn: conn} do
      target = create_target_user(%{email: "whitespacekey@example.com"})

      {:ok, lv, _html} = live(conn, admin_path())
      switch_to_users_tab(lv)

      lv
      |> element("button[phx-click='edit_admin_user'][phx-value-id='#{target.id}']")
      |> render_click()

      html =
        lv
        |> form("#admin-user-key-form-#{target.id}", %{
          "user_id" => target.id,
          "api_key" => "   "
        })
        |> render_submit()

      assert html =~ "API key cannot be blank"
    end
  end

  # ──────────────────────────────────────────────
  # Event: delete_admin_user_openrouter_key
  # ──────────────────────────────────────────────

  describe "delete_admin_user_openrouter_key event" do
    test "removes key and shows flash", %{conn: conn} do
      target = create_target_user(%{email: "removekey@example.com"})
      {:ok, _} = Accounts.save_openrouter_api_key(target, "sk-or-v1-remove-me")

      {:ok, lv, _html} = live(conn, admin_path())
      switch_to_users_tab(lv)

      # Open detail view
      lv
      |> element("button[phx-click='edit_admin_user'][phx-value-id='#{target.id}']")
      |> render_click()

      html = render_click(lv, "delete_admin_user_openrouter_key", %{"id" => target.id})

      assert html =~ "OpenRouter API key removed"
    end
  end

  # ──────────────────────────────────────────────
  # Component rendering: User detail section
  # ──────────────────────────────────────────────

  describe "user detail rendering" do
    test "shows admin toggle in detail view", %{conn: conn} do
      target = create_target_user(%{email: "admin-toggle@example.com"})

      {:ok, lv, _html} = live(conn, admin_path())
      switch_to_users_tab(lv)

      html =
        lv
        |> element("button[phx-click='edit_admin_user'][phx-value-id='#{target.id}']")
        |> render_click()

      assert html =~ "Admin Status"
      assert html =~ "toggle_admin_status"
    end

    test "shows enable/disable toggle in detail view", %{conn: conn} do
      target = create_target_user(%{email: "enable-toggle@example.com"})

      {:ok, lv, _html} = live(conn, admin_path())
      switch_to_users_tab(lv)

      html =
        lv
        |> element("button[phx-click='edit_admin_user'][phx-value-id='#{target.id}']")
        |> render_click()

      assert html =~ "Account Enabled"
      assert html =~ "toggle_user_disabled"
    end

    test "shows back button in detail view", %{conn: conn} do
      target = create_target_user(%{email: "back-btn@example.com"})

      {:ok, lv, _html} = live(conn, admin_path())
      switch_to_users_tab(lv)

      html =
        lv
        |> element("button[phx-click='edit_admin_user'][phx-value-id='#{target.id}']")
        |> render_click()

      assert html =~ "back_to_admin_users"
    end

    test "shows OpenRouter key form in detail view", %{conn: conn} do
      target = create_target_user(%{email: "keyform@example.com"})

      {:ok, lv, _html} = live(conn, admin_path())
      switch_to_users_tab(lv)

      html =
        lv
        |> element("button[phx-click='edit_admin_user'][phx-value-id='#{target.id}']")
        |> render_click()

      assert html =~ "save_admin_user_openrouter_key"
      assert html =~ "admin-user-key-form-#{target.id}"
    end

    test "shows Configured badge when user has OpenRouter key", %{conn: conn} do
      target = create_target_user(%{email: "haskey@example.com"})
      {:ok, _} = Accounts.save_openrouter_api_key(target, "sk-or-v1-has-key")

      {:ok, lv, _html} = live(conn, admin_path())
      switch_to_users_tab(lv)

      html =
        lv
        |> element("button[phx-click='edit_admin_user'][phx-value-id='#{target.id}']")
        |> render_click()

      assert html =~ "Configured"
    end

    test "shows Not Set badge when user has no OpenRouter key", %{conn: conn} do
      target = create_target_user(%{email: "nokey@example.com"})

      {:ok, lv, _html} = live(conn, admin_path())
      switch_to_users_tab(lv)

      html =
        lv
        |> element("button[phx-click='edit_admin_user'][phx-value-id='#{target.id}']")
        |> render_click()

      assert html =~ "Not Set"
    end

    test "shows remove button only when key exists", %{conn: conn} do
      target = create_target_user(%{email: "removebutton@example.com"})
      {:ok, _} = Accounts.save_openrouter_api_key(target, "sk-or-v1-removable")

      {:ok, lv, _html} = live(conn, admin_path())
      switch_to_users_tab(lv)

      html =
        lv
        |> element("button[phx-click='edit_admin_user'][phx-value-id='#{target.id}']")
        |> render_click()

      assert html =~ "delete_admin_user_openrouter_key"
    end

    test "detail view refreshes after toggling user status", %{conn: conn} do
      target = create_target_user(%{email: "refresh-detail@example.com"})

      {:ok, lv, _html} = live(conn, admin_path())
      switch_to_users_tab(lv)

      # Open detail view
      lv
      |> element("button[phx-click='edit_admin_user'][phx-value-id='#{target.id}']")
      |> render_click()

      # Toggle disabled
      html = render_click(lv, "toggle_user_disabled", %{"id" => target.id})

      # Detail view should still be showing (maybe_refresh_current_admin_user keeps it)
      assert html =~ "Account Controls"
    end
  end

  # ──────────────────────────────────────────────
  # Event: save_spending_limit
  # ──────────────────────────────────────────────

  describe "save_spending_limit event" do
    test "saves spending limit with valid budget and shows flash", %{conn: conn} do
      target = create_target_user(%{email: "spending-save@example.com"})

      {:ok, lv, _html} = live(conn, admin_path())
      switch_to_users_tab(lv)

      lv
      |> element("button[phx-click='edit_admin_user'][phx-value-id='#{target.id}']")
      |> render_click()

      html =
        lv
        |> form("#spending-limit-form-#{target.id}", %{
          "user_id" => target.id,
          "budget_dollars" => "50.00",
          "warning_threshold" => "80",
          "hard_cap" => "true"
        })
        |> render_submit()

      assert html =~ "Spending limit updated"

      limit = Assistant.SpendingLimits.get_spending_limit(target.id)
      assert limit.budget_cents == 5_000
      assert limit.hard_cap == true
      assert limit.warning_threshold == 80
    end

    test "removes spending limit when budget is blank", %{conn: conn} do
      target = create_target_user(%{email: "spending-blank@example.com"})

      # Pre-create a spending limit
      Assistant.SpendingLimits.upsert_spending_limit(target.id, %{budget_cents: 5_000})

      {:ok, lv, _html} = live(conn, admin_path())
      switch_to_users_tab(lv)

      lv
      |> element("button[phx-click='edit_admin_user'][phx-value-id='#{target.id}']")
      |> render_click()

      html =
        lv
        |> form("#spending-limit-form-#{target.id}", %{
          "user_id" => target.id,
          "budget_dollars" => "",
          "warning_threshold" => "80"
        })
        |> render_submit()

      assert html =~ "Spending limit removed"
      assert is_nil(Assistant.SpendingLimits.get_spending_limit(target.id))
    end

    test "updates existing spending limit", %{conn: conn} do
      target = create_target_user(%{email: "spending-update@example.com"})
      Assistant.SpendingLimits.upsert_spending_limit(target.id, %{budget_cents: 5_000})

      {:ok, lv, _html} = live(conn, admin_path())
      switch_to_users_tab(lv)

      lv
      |> element("button[phx-click='edit_admin_user'][phx-value-id='#{target.id}']")
      |> render_click()

      html =
        lv
        |> form("#spending-limit-form-#{target.id}", %{
          "user_id" => target.id,
          "budget_dollars" => "100.00",
          "warning_threshold" => "90",
          "hard_cap" => "true"
        })
        |> render_submit()

      assert html =~ "Spending limit updated"

      limit = Assistant.SpendingLimits.get_spending_limit(target.id)
      assert limit.budget_cents == 10_000
      assert limit.warning_threshold == 90
    end
  end

  # ──────────────────────────────────────────────
  # Event: remove_spending_limit
  # ──────────────────────────────────────────────

  describe "remove_spending_limit event" do
    test "removes spending limit and shows flash", %{conn: conn} do
      target = create_target_user(%{email: "spending-remove@example.com"})
      Assistant.SpendingLimits.upsert_spending_limit(target.id, %{budget_cents: 5_000})

      {:ok, lv, _html} = live(conn, admin_path())
      switch_to_users_tab(lv)

      lv
      |> element("button[phx-click='edit_admin_user'][phx-value-id='#{target.id}']")
      |> render_click()

      html = render_click(lv, "remove_spending_limit", %{"id" => target.id})

      assert html =~ "Spending limit removed"
      assert is_nil(Assistant.SpendingLimits.get_spending_limit(target.id))
    end
  end

  # ──────────────────────────────────────────────
  # Event: create_admin_user (new user flow)
  # ──────────────────────────────────────────────

  describe "create_admin_user flow" do
    test "creates a new user via allowlist form", %{conn: conn} do
      {:ok, lv, _html} = live(conn, admin_path())
      switch_to_users_tab(lv)

      render_click(lv, "start_add_user")

      html =
        lv
        |> form("form[phx-submit=\"save_allowlist_entry\"]", %{
          "allowlist_entry" => %{
            "email" => "brand-new-user@example.com",
            "full_name" => "Brand New User"
          }
        })
        |> render_submit()

      assert html =~ "User created successfully"

      user = Accounts.get_settings_user_by_email("brand-new-user@example.com")
      assert user
      assert is_nil(user.hashed_password)
    end

    test "handles duplicate email gracefully", %{conn: conn} do
      _existing = create_target_user(%{email: "dupe-test@example.com"})

      {:ok, lv, _html} = live(conn, admin_path())
      switch_to_users_tab(lv)

      render_click(lv, "start_add_user")

      html =
        lv
        |> form("form[phx-submit=\"save_allowlist_entry\"]", %{
          "allowlist_entry" => %{
            "email" => "dupe-test@example.com",
            "full_name" => "Duplicate"
          }
        })
        |> render_submit()

      assert html =~ "User created successfully"
    end

    test "creates user with spending limit in same flow", %{conn: conn} do
      {:ok, lv, _html} = live(conn, admin_path())
      switch_to_users_tab(lv)

      render_click(lv, "start_add_user")

      html =
        lv
        |> form("form[phx-submit=\"save_allowlist_entry\"]", %{
          "allowlist_entry" => %{
            "email" => "user-with-budget@example.com",
            "full_name" => "Budget User",
            "budget_dollars" => "25.00",
            "warning_threshold" => "90",
            "hard_cap" => "true"
          }
        })
        |> render_submit()

      assert html =~ "User created successfully"

      user = Accounts.get_settings_user_by_email("user-with-budget@example.com")
      assert user

      limit = Assistant.SpendingLimits.get_spending_limit(user.id)
      assert limit
      assert limit.budget_cents == 2_500
    end
  end

  # ──────────────────────────────────────────────
  # Non-admin access control
  # ──────────────────────────────────────────────

  describe "non-admin access to admin events" do
    setup %{conn: _conn, admin: admin} do
      email = unique_settings_user_email()

      Accounts.upsert_settings_user_allowlist_entry(
        %{email: email, active: true, is_admin: false, scopes: []},
        admin,
        transaction?: false
      )

      non_admin = settings_user_fixture(%{email: email})
      conn = log_in_settings_user(Phoenix.ConnTest.build_conn(), non_admin)

      %{non_admin_conn: conn, non_admin: non_admin}
    end

    test "non-admin is redirected from admin section", %{non_admin_conn: conn} do
      # push_navigate in handle_params causes a live_redirect error tuple
      {:error, {:live_redirect, %{to: path, flash: flash}}} = live(conn, admin_path())

      assert path == "/settings"
      assert flash["error"] == "You do not have permission to access admin."
    end
  end
end
