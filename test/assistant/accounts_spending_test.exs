defmodule Assistant.AccountsSpendingTest do
  use Assistant.DataCase, async: true

  alias Assistant.Accounts
  alias Assistant.Accounts.SettingsUser

  import Assistant.AccountsFixtures

  # ──────────────────────────────────────────────
  # P0: create_settings_user_from_admin/2
  # ──────────────────────────────────────────────

  describe "create_settings_user_from_admin/2" do
    test "creates a settings_user with nil hashed_password" do
      attrs = %{email: "newuser@example.com", full_name: "New User"}

      assert {:ok, %SettingsUser{} = user} = Accounts.create_settings_user_from_admin(attrs)
      assert user.email == "newuser@example.com"
      assert user.full_name == "New User"
      assert is_nil(user.hashed_password)
    end

    test "creates allowlist entry alongside settings_user" do
      attrs = %{email: "admin-created@example.com"}

      assert {:ok, %SettingsUser{}} = Accounts.create_settings_user_from_admin(attrs)

      # Verify allowlist entry was created
      entries = Repo.all(Assistant.Accounts.SettingsUserAllowlistEntry)
      assert Enum.any?(entries, &(&1.email == "admin-created@example.com"))
    end

    test "returns {:error, :missing_email} when email is nil" do
      assert {:error, :missing_email} = Accounts.create_settings_user_from_admin(%{})
    end

    test "returns {:error, :missing_email} when email is empty string" do
      assert {:error, :missing_email} = Accounts.create_settings_user_from_admin(%{email: ""})
    end

    test "returns existing user if email already exists" do
      existing = settings_user_fixture()
      attrs = %{email: existing.email}

      assert {:ok, %SettingsUser{} = returned} = Accounts.create_settings_user_from_admin(attrs)
      assert returned.id == existing.id
    end

    test "sets is_admin on allowlist entry when specified" do
      attrs = %{email: "new-admin@example.com", is_admin: true}

      assert {:ok, %SettingsUser{}} = Accounts.create_settings_user_from_admin(attrs)

      # The user gets synced from allowlist — check the user's admin flag
      user = Accounts.get_settings_user_by_email("new-admin@example.com")
      assert user.is_admin
    end

    test "sets access_scopes on allowlist entry" do
      attrs = %{email: "scoped-user@example.com", access_scopes: ["chat", "integrations"]}

      assert {:ok, %SettingsUser{}} = Accounts.create_settings_user_from_admin(attrs)

      user = Accounts.get_settings_user_by_email("scoped-user@example.com")
      assert "chat" in user.access_scopes
      assert "integrations" in user.access_scopes
    end

    test "accepts string keys in attrs map" do
      attrs = %{"email" => "string-keys@example.com", "full_name" => "String Keys"}

      assert {:ok, %SettingsUser{} = user} = Accounts.create_settings_user_from_admin(attrs)
      assert user.email == "string-keys@example.com"
      assert user.full_name == "String Keys"
    end

    test "does not send invite by default" do
      attrs = %{email: "no-invite@example.com"}

      # Should succeed without providing magic_link_url_fun
      assert {:ok, %SettingsUser{}} = Accounts.create_settings_user_from_admin(attrs)
    end

    test "sends invite when send_invite: true and magic_link_url_fun provided" do
      attrs = %{email: "invite-user@example.com"}

      assert {:ok, %SettingsUser{}} =
               Accounts.create_settings_user_from_admin(attrs,
                 send_invite: true,
                 magic_link_url_fun: &"http://test/login/#{&1}"
               )
    end
  end

  # ──────────────────────────────────────────────
  # P1: full_name sync from allowlist
  # ──────────────────────────────────────────────

  describe "full_name on settings_user" do
    test "full_name field is stored on settings_user" do
      user = settings_user_fixture()

      updated =
        user
        |> SettingsUser.profile_changeset(%{full_name: "John Doe"})
        |> Repo.update!()

      assert updated.full_name == "John Doe"
    end

    test "full_name validates max length" do
      user = settings_user_fixture()
      long_name = String.duplicate("a", 161)

      changeset = SettingsUser.profile_changeset(user, %{full_name: long_name})
      refute changeset.valid?
      assert errors_on(changeset).full_name
    end

    test "full_name can be nil" do
      user = settings_user_fixture()

      updated =
        user
        |> SettingsUser.profile_changeset(%{full_name: nil})
        |> Repo.update!()

      assert is_nil(updated.full_name)
    end
  end
end
