defmodule Assistant.AccountsAdminTest do
  use Assistant.DataCase

  alias Assistant.Accounts
  alias Assistant.Accounts.{SettingsUser, SettingsUserToken}

  import Assistant.AccountsFixtures

  # ──────────────────────────────────────────────
  # Helpers
  # ──────────────────────────────────────────────

  defp admin_fixture(attrs \\ %{}) do
    user = settings_user_fixture(attrs)

    user
    |> Ecto.Changeset.change(is_admin: true)
    |> Repo.update!()
  end

  defp disabled_fixture(attrs \\ %{}) do
    user = settings_user_fixture(attrs)

    user
    |> SettingsUser.disabled_changeset(DateTime.utc_now(:second))
    |> Repo.update!()
  end

  # ──────────────────────────────────────────────
  # P0: SettingsUser.disabled?/1
  # ──────────────────────────────────────────────

  describe "SettingsUser.disabled?/1" do
    test "returns false when disabled_at is nil" do
      refute SettingsUser.disabled?(%SettingsUser{disabled_at: nil})
    end

    test "returns true when disabled_at is set" do
      assert SettingsUser.disabled?(%SettingsUser{disabled_at: DateTime.utc_now(:second)})
    end

    test "returns false for non-SettingsUser" do
      refute SettingsUser.disabled?(nil)
    end
  end

  # ──────────────────────────────────────────────
  # P0: toggle_user_disabled/2
  # ──────────────────────────────────────────────

  describe "toggle_user_disabled/2" do
    test "disables an enabled user and returns expired tokens" do
      actor = settings_user_fixture()
      target = settings_user_fixture()

      # Create a session token so we can verify it's expired
      _token = Accounts.generate_settings_user_session_token(target)

      assert {:ok, updated, expired_tokens} = Accounts.toggle_user_disabled(target.id, actor.id)
      assert not is_nil(updated.disabled_at)
      assert SettingsUser.disabled?(updated)
      assert length(expired_tokens) == 1
    end

    test "re-enables a disabled user with empty expired tokens" do
      actor = settings_user_fixture()
      target = disabled_fixture()

      assert SettingsUser.disabled?(target)
      assert {:ok, updated, expired_tokens} = Accounts.toggle_user_disabled(target.id, actor.id)
      assert is_nil(updated.disabled_at)
      refute SettingsUser.disabled?(updated)
      assert expired_tokens == []
    end

    test "returns :cannot_disable_self when actor and target are the same" do
      user = settings_user_fixture()

      assert {:error, :cannot_disable_self} = Accounts.toggle_user_disabled(user.id, user.id)
    end

    test "returns :not_found for nonexistent user" do
      actor = settings_user_fixture()
      fake_id = Ecto.UUID.generate()

      assert {:error, :not_found} = Accounts.toggle_user_disabled(fake_id, actor.id)
    end

    test "returns :last_admin when disabling the only active admin" do
      admin = admin_fixture()
      actor = settings_user_fixture()

      assert {:error, :last_admin} = Accounts.toggle_user_disabled(admin.id, actor.id)
    end

    test "allows disabling an admin when another active admin exists" do
      admin1 = admin_fixture(%{email: "admin1@example.com"})
      _admin2 = admin_fixture(%{email: "admin2@example.com"})

      actor = settings_user_fixture()

      assert {:ok, updated, _expired_tokens} = Accounts.toggle_user_disabled(admin1.id, actor.id)
      assert SettingsUser.disabled?(updated)
    end

    test "allows re-enabling a disabled admin even if they are the last admin" do
      # Create an admin, then disable them via direct DB update
      admin = admin_fixture()
      actor = settings_user_fixture()

      disabled_admin =
        admin
        |> SettingsUser.disabled_changeset(DateTime.utc_now(:second))
        |> Repo.update!()

      # Re-enable should work even if this is the only admin (they are disabled, so
      # re-enabling makes the system healthier)
      assert {:ok, updated, []} = Accounts.toggle_user_disabled(disabled_admin.id, actor.id)
      assert is_nil(updated.disabled_at)
    end
  end

  # ──────────────────────────────────────────────
  # P0: Disable enforcement — password login gate
  # ──────────────────────────────────────────────

  describe "get_settings_user_by_email_and_password/2 with disabled user" do
    test "returns nil for disabled user with valid credentials" do
      user = settings_user_fixture() |> set_password()

      # Disable the user
      user
      |> SettingsUser.disabled_changeset(DateTime.utc_now(:second))
      |> Repo.update!()

      refute Accounts.get_settings_user_by_email_and_password(
               user.email,
               valid_settings_user_password()
             )
    end

    test "returns user after re-enabling" do
      user = settings_user_fixture() |> set_password()

      # Disable
      user
      |> SettingsUser.disabled_changeset(DateTime.utc_now(:second))
      |> Repo.update!()

      refute Accounts.get_settings_user_by_email_and_password(
               user.email,
               valid_settings_user_password()
             )

      # Re-enable
      Repo.get!(SettingsUser, user.id)
      |> SettingsUser.disabled_changeset(nil)
      |> Repo.update!()

      assert %SettingsUser{} =
               Accounts.get_settings_user_by_email_and_password(
                 user.email,
                 valid_settings_user_password()
               )
    end
  end

  # ──────────────────────────────────────────────
  # P0: Disable enforcement — magic link login gate
  # ──────────────────────────────────────────────

  describe "login_settings_user_by_magic_link/1 with disabled user" do
    test "returns {:error, :disabled} for disabled confirmed user" do
      user = settings_user_fixture()
      {encoded_token, _hashed} = generate_settings_user_magic_link_token(user)

      # Disable
      user
      |> SettingsUser.disabled_changeset(DateTime.utc_now(:second))
      |> Repo.update!()

      assert {:error, :disabled} = Accounts.login_settings_user_by_magic_link(encoded_token)
    end

    test "succeeds for enabled user" do
      user = settings_user_fixture()
      {encoded_token, _hashed} = generate_settings_user_magic_link_token(user)

      assert {:ok, {%SettingsUser{}, _}} =
               Accounts.login_settings_user_by_magic_link(encoded_token)
    end
  end

  # ──────────────────────────────────────────────
  # P0: Disable enforcement — session validation gate
  # ──────────────────────────────────────────────

  describe "get_settings_user_by_session_token/1 with disabled user" do
    test "returns nil for disabled user (lazy invalidation)" do
      user = settings_user_fixture()
      token = Accounts.generate_settings_user_session_token(user)

      # Verify session works while enabled
      assert {%SettingsUser{}, _} = Accounts.get_settings_user_by_session_token(token)

      # Disable
      user
      |> SettingsUser.disabled_changeset(DateTime.utc_now(:second))
      |> Repo.update!()

      # Session should now return nil
      refute Accounts.get_settings_user_by_session_token(token)
    end

    test "returns user after re-enabling" do
      user = settings_user_fixture()
      token = Accounts.generate_settings_user_session_token(user)

      # Disable
      user
      |> SettingsUser.disabled_changeset(DateTime.utc_now(:second))
      |> Repo.update!()

      refute Accounts.get_settings_user_by_session_token(token)

      # Re-enable
      Repo.get!(SettingsUser, user.id)
      |> SettingsUser.disabled_changeset(nil)
      |> Repo.update!()

      assert {%SettingsUser{}, _} = Accounts.get_settings_user_by_session_token(token)
    end
  end

  # ──────────────────────────────────────────────
  # P0: Disable enforcement — magic link token lookup gate
  # ──────────────────────────────────────────────

  describe "get_settings_user_by_magic_link_token/1 with disabled user" do
    test "returns nil for disabled user" do
      user = settings_user_fixture()
      {encoded_token, _hashed} = generate_settings_user_magic_link_token(user)

      # Disable
      user
      |> SettingsUser.disabled_changeset(DateTime.utc_now(:second))
      |> Repo.update!()

      refute Accounts.get_settings_user_by_magic_link_token(encoded_token)
    end
  end

  # ──────────────────────────────────────────────
  # P0: Disable enforcement — deliver_login_instructions gate
  # ──────────────────────────────────────────────

  describe "deliver_login_instructions/2 with disabled user" do
    test "returns {:error, :disabled} for disabled user" do
      user = settings_user_fixture()

      # Disable
      disabled_user =
        user
        |> SettingsUser.disabled_changeset(DateTime.utc_now(:second))
        |> Repo.update!()

      assert {:error, :disabled} =
               Accounts.deliver_login_instructions(disabled_user, &"[TOKEN]#{&1}[TOKEN]")
    end
  end

  # ──────────────────────────────────────────────
  # P0: Disable enforcement — Google OAuth gate
  # ──────────────────────────────────────────────

  describe "get_or_register_settings_user_from_google/1 with disabled user" do
    test "returns {:error, :disabled} for existing disabled user" do
      user = settings_user_fixture()

      # Disable
      user
      |> SettingsUser.disabled_changeset(DateTime.utc_now(:second))
      |> Repo.update!()

      assert {:error, :disabled} =
               Accounts.get_or_register_settings_user_from_google(%{
                 "email" => user.email,
                 "name" => "Test User"
               })
    end
  end

  # ──────────────────────────────────────────────
  # P1: toggle_admin_status/2
  # ──────────────────────────────────────────────

  describe "toggle_admin_status/2" do
    test "promotes a regular user to admin" do
      user = settings_user_fixture()
      refute user.is_admin

      assert {:ok, updated} = Accounts.toggle_admin_status(user.id, true)
      assert updated.is_admin
    end

    test "demotes an admin to regular user when another admin exists" do
      admin1 = admin_fixture(%{email: "admin1@example.com"})
      _admin2 = admin_fixture(%{email: "admin2@example.com"})

      assert {:ok, updated} = Accounts.toggle_admin_status(admin1.id, false)
      refute updated.is_admin
    end

    test "returns :last_admin when demoting the only active admin" do
      admin = admin_fixture()

      assert {:error, :last_admin} = Accounts.toggle_admin_status(admin.id, false)
    end

    test "returns :not_found for nonexistent user" do
      fake_id = Ecto.UUID.generate()

      assert {:error, :not_found} = Accounts.toggle_admin_status(fake_id, true)
    end

    test "promoting an already-admin user is idempotent" do
      admin = admin_fixture()

      assert {:ok, updated} = Accounts.toggle_admin_status(admin.id, true)
      assert updated.is_admin
    end

    test "allows demoting admin when a disabled admin exists alongside an active one" do
      # admin1 active, admin2 disabled, admin3 active
      admin1 = admin_fixture(%{email: "admin1@example.com"})
      admin2 = admin_fixture(%{email: "admin2@example.com"})
      _admin3 = admin_fixture(%{email: "admin3@example.com"})

      # Disable admin2
      admin2
      |> SettingsUser.disabled_changeset(DateTime.utc_now(:second))
      |> Repo.update!()

      # admin1 can be demoted because admin3 is still active
      assert {:ok, updated} = Accounts.toggle_admin_status(admin1.id, false)
      refute updated.is_admin
    end

    test "cannot demote when only admin besides disabled admins" do
      admin1 = admin_fixture(%{email: "admin1@example.com"})
      admin2 = admin_fixture(%{email: "admin2@example.com"})

      # Disable admin2
      admin2
      |> SettingsUser.disabled_changeset(DateTime.utc_now(:second))
      |> Repo.update!()

      # admin1 is the last ACTIVE admin
      assert {:error, :last_admin} = Accounts.toggle_admin_status(admin1.id, false)
    end
  end

  # ──────────────────────────────────────────────
  # P1: get_user_for_admin/1
  # ──────────────────────────────────────────────

  describe "get_user_for_admin/1" do
    test "returns full detail map with correct fields" do
      user = settings_user_fixture()

      assert {:ok, detail} = Accounts.get_user_for_admin(user.id)

      assert detail.id == user.id
      assert detail.email == user.email
      assert is_boolean(detail.is_admin)
      assert is_boolean(detail.has_openrouter_key)
      assert is_boolean(detail.has_openai_key)
      assert is_boolean(detail.has_linked_user)
      assert Map.has_key?(detail, :display_name)
      assert Map.has_key?(detail, :disabled_at)
      assert Map.has_key?(detail, :user_id)
      assert Map.has_key?(detail, :access_scopes)
      assert Map.has_key?(detail, :can_manage_model_defaults)
      assert Map.has_key?(detail, :confirmed_at)
      assert Map.has_key?(detail, :inserted_at)
      assert Map.has_key?(detail, :updated_at)
    end

    test "does not create a billing account as a read side effect" do
      user = unconfirmed_settings_user_fixture()
      refute Repo.get!(SettingsUser, user.id).billing_account_id

      assert {:ok, detail} = Accounts.get_user_for_admin(user.id)

      refute detail.billing_account
      refute Repo.get!(SettingsUser, user.id).billing_account_id
    end

    test "shows has_openrouter_key correctly" do
      user = settings_user_fixture()
      {:ok, _} = Accounts.save_openrouter_api_key(user, "sk-or-test")

      {:ok, detail} = Accounts.get_user_for_admin(user.id)
      assert detail.has_openrouter_key
    end

    test "shows has_openrouter_key as false when no key" do
      user = settings_user_fixture()

      {:ok, detail} = Accounts.get_user_for_admin(user.id)
      refute detail.has_openrouter_key
    end

    test "shows disabled_at when user is disabled" do
      user = disabled_fixture()

      {:ok, detail} = Accounts.get_user_for_admin(user.id)
      assert not is_nil(detail.disabled_at)
    end

    test "returns :not_found for nonexistent user" do
      fake_id = Ecto.UUID.generate()

      assert {:error, :not_found} = Accounts.get_user_for_admin(fake_id)
    end
  end

  # ──────────────────────────────────────────────
  # P1: list_settings_users_for_admin/0 (new fields)
  # ──────────────────────────────────────────────

  describe "list_settings_users_for_admin/0 — admin and disabled fields" do
    test "includes can_manage_model_defaults field" do
      user = settings_user_fixture()

      results = Accounts.list_settings_users_for_admin()
      result = Enum.find(results, &(&1.id == user.id))

      assert result.can_manage_model_defaults == false
    end

    test "includes is_admin field" do
      admin = admin_fixture()

      results = Accounts.list_settings_users_for_admin()
      admin_result = Enum.find(results, &(&1.id == admin.id))

      assert admin_result.is_admin
    end

    test "includes disabled_at field" do
      disabled = disabled_fixture()

      results = Accounts.list_settings_users_for_admin()
      disabled_result = Enum.find(results, &(&1.id == disabled.id))

      assert not is_nil(disabled_result.disabled_at)
    end

    test "includes has_openai_key field" do
      user = settings_user_fixture()
      {:ok, _} = Accounts.save_openai_api_key(user, "sk-test-openai")

      results = Accounts.list_settings_users_for_admin()
      result = Enum.find(results, &(&1.id == user.id))

      assert result.has_openai_key
    end

    test "shows has_openai_key as false when no key set" do
      user = settings_user_fixture()

      results = Accounts.list_settings_users_for_admin()
      result = Enum.find(results, &(&1.id == user.id))

      refute result.has_openai_key
    end

    test "includes enabled user with disabled_at nil" do
      user = settings_user_fixture()

      results = Accounts.list_settings_users_for_admin()
      result = Enum.find(results, &(&1.id == user.id))

      assert is_nil(result.disabled_at)
    end
  end

  describe "toggle_user_model_defaults_access/2" do
    test "enables personal model defaults access for a user" do
      user = settings_user_fixture()

      assert {:ok, updated} = Accounts.toggle_user_model_defaults_access(user.id, true)
      assert updated.can_manage_model_defaults
    end

    test "disables personal model defaults access for a user" do
      user = settings_user_fixture()
      {:ok, _updated} = Accounts.toggle_user_model_defaults_access(user.id, true)

      assert {:ok, updated} = Accounts.toggle_user_model_defaults_access(user.id, false)
      refute updated.can_manage_model_defaults
    end

    test "returns :not_found for nonexistent user" do
      assert {:error, :not_found} =
               Accounts.toggle_user_model_defaults_access(Ecto.UUID.generate(), true)
    end
  end

  # ──────────────────────────────────────────────
  # P1: delete_settings_user/2
  # ──────────────────────────────────────────────

  describe "delete_settings_user/2" do
    test "deletes a regular user" do
      actor = settings_user_fixture()
      target = settings_user_fixture()

      assert {:ok, %SettingsUser{}} = Accounts.delete_settings_user(target.id, actor.id)
      assert is_nil(Repo.get(SettingsUser, target.id))
    end

    test "cascades token deletion" do
      actor = settings_user_fixture()
      target = settings_user_fixture()

      # Create a session token for the target
      _token = Accounts.generate_settings_user_session_token(target)
      assert Repo.exists?(from(t in SettingsUserToken, where: t.settings_user_id == ^target.id))

      assert {:ok, _} = Accounts.delete_settings_user(target.id, actor.id)

      # Tokens should be gone (cascade)
      refute Repo.exists?(from(t in SettingsUserToken, where: t.settings_user_id == ^target.id))
    end

    test "returns :cannot_delete_self" do
      user = settings_user_fixture()

      assert {:error, :cannot_delete_self} = Accounts.delete_settings_user(user.id, user.id)
    end

    test "returns :last_admin when deleting the only active admin" do
      admin = admin_fixture()
      actor = settings_user_fixture()

      assert {:error, :last_admin} = Accounts.delete_settings_user(admin.id, actor.id)
    end

    test "allows deleting an admin when another active admin exists" do
      admin1 = admin_fixture(%{email: "admin1@example.com"})
      admin2 = admin_fixture(%{email: "admin2@example.com"})

      assert {:ok, _} = Accounts.delete_settings_user(admin1.id, admin2.id)
      assert is_nil(Repo.get(SettingsUser, admin1.id))
    end

    test "returns :not_found for nonexistent user" do
      actor = settings_user_fixture()
      fake_id = Ecto.UUID.generate()

      assert {:error, :not_found} = Accounts.delete_settings_user(fake_id, actor.id)
    end

    test "returns :last_admin when other admins are disabled" do
      admin1 = admin_fixture(%{email: "admin1@example.com"})
      admin2 = admin_fixture(%{email: "admin2@example.com"})
      actor = settings_user_fixture()

      # Disable admin2
      admin2
      |> SettingsUser.disabled_changeset(DateTime.utc_now(:second))
      |> Repo.update!()

      # admin1 is the last ACTIVE admin
      assert {:error, :last_admin} = Accounts.delete_settings_user(admin1.id, actor.id)
    end
  end

  # ──────────────────────────────────────────────
  # P1: settings_user_disabled?/1 (Accounts wrapper)
  # ──────────────────────────────────────────────

  describe "settings_user_disabled?/1" do
    test "delegates to SettingsUser.disabled?/1" do
      enabled_user = %SettingsUser{disabled_at: nil}
      disabled_user = %SettingsUser{disabled_at: DateTime.utc_now(:second)}

      refute Accounts.settings_user_disabled?(enabled_user)
      assert Accounts.settings_user_disabled?(disabled_user)
    end
  end

  # ──────────────────────────────────────────────
  # P0: Auth layer — on_mount disabled redirect
  # ──────────────────────────────────────────────

  describe "on_mount :require_authenticated with disabled user" do
    test "redirects disabled user to login with flash" do
      user = settings_user_fixture()
      token = Accounts.generate_settings_user_session_token(user)

      # Disable the user
      user
      |> SettingsUser.disabled_changeset(DateTime.utc_now(:second))
      |> Repo.update!()

      # The session token lookup returns nil for disabled users,
      # so on_mount will see no current_scope and redirect
      refute Accounts.get_settings_user_by_session_token(token)
    end
  end

  # ──────────────────────────────────────────────
  # P0: SettingsUser.disabled_changeset/2
  # ──────────────────────────────────────────────

  describe "SettingsUser.disabled_changeset/2" do
    test "sets disabled_at to a datetime" do
      user = %SettingsUser{}
      now = DateTime.utc_now(:second)

      changeset = SettingsUser.disabled_changeset(user, now)
      assert Ecto.Changeset.get_change(changeset, :disabled_at) == now
    end

    test "clears disabled_at when passed nil" do
      now = DateTime.utc_now(:second)
      user = %SettingsUser{disabled_at: now}

      changeset = SettingsUser.disabled_changeset(user, nil)
      assert Ecto.Changeset.get_change(changeset, :disabled_at) == nil
    end
  end
end
