defmodule Assistant.Accounts.ScopeTest do
  use Assistant.DataCase, async: true

  alias Assistant.Accounts.Scope

  describe "can_configure_integrations?/1" do
    test "returns true when scope has admin? true" do
      scope = %Scope{admin?: true, settings_user: %{billing_role: "member"}}
      assert Scope.can_configure_integrations?(scope)
    end

    test "returns true when billing_role is owner and not admin" do
      scope = %Scope{admin?: false, settings_user: %{billing_role: "owner"}}
      assert Scope.can_configure_integrations?(scope)
    end

    test "returns true when billing_role is admin and not admin" do
      scope = %Scope{admin?: false, settings_user: %{billing_role: "admin"}}
      assert Scope.can_configure_integrations?(scope)
    end

    test "returns false when billing_role is member and not admin" do
      scope = %Scope{admin?: false, settings_user: %{billing_role: "member"}}
      refute Scope.can_configure_integrations?(scope)
    end

    test "returns false when billing_role is nil and not admin" do
      scope = %Scope{admin?: false, settings_user: %{billing_role: nil}}
      refute Scope.can_configure_integrations?(scope)
    end

    test "returns false for nil scope" do
      refute Scope.can_configure_integrations?(nil)
    end

    test "returns false when settings_user is nil" do
      scope = %Scope{admin?: false, settings_user: nil}
      refute Scope.can_configure_integrations?(scope)
    end

    test "admin flag takes precedence over non-qualifying billing_role" do
      scope = %Scope{admin?: true, settings_user: %{billing_role: nil}}
      assert Scope.can_configure_integrations?(scope)
    end
  end

  describe "can_configure_integrations?/1 with DB-backed scope" do
    import Assistant.AccountsFixtures

    test "returns true for scope built from admin user" do
      admin = admin_settings_user_fixture()
      scope = Scope.for_settings_user(admin)
      assert Scope.can_configure_integrations?(scope)
    end

    test "returns false for scope built from regular user (default member role)" do
      user = settings_user_fixture()
      scope = Scope.for_settings_user(user)
      refute Scope.can_configure_integrations?(scope)
    end

    test "returns true for scope built from user with billing_role owner" do
      user = settings_user_fixture()

      user =
        user
        |> Ecto.Changeset.change(billing_role: "owner")
        |> Assistant.Repo.update!()

      scope = Scope.for_settings_user(user)
      assert Scope.can_configure_integrations?(scope)
    end
  end

  describe "for_settings_user/1" do
    import Assistant.AccountsFixtures

    test "sets admin? to true when is_admin is true" do
      settings_user = settings_user_fixture() |> Map.put(:is_admin, true) |> Map.put(:access_scopes, [])
      scope = Scope.for_settings_user(settings_user)
      assert scope.admin? == true
      assert "admin" in scope.privileges
    end

    test "sets admin? to false when is_admin is false" do
      settings_user = settings_user_fixture() |> Map.put(:is_admin, false) |> Map.put(:access_scopes, [])
      scope = Scope.for_settings_user(settings_user)
      assert scope.admin? == false
      refute "admin" in scope.privileges
    end

    test "returns nil for nil input" do
      assert Scope.for_settings_user(nil) == nil
    end
  end
end
