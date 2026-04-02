defmodule AssistantWeb.Components.SettingsPage.HelpersTest do
  use Assistant.DataCase, async: true

  alias Assistant.Accounts.Scope
  alias AssistantWeb.Components.SettingsPage.Helpers

  describe "nav_items_for/1 with scope struct" do
    test "includes admin tab for admin scope" do
      scope = %Scope{admin?: true, settings_user: %{billing_role: "member"}, privileges: ["admin"]}
      items = Helpers.nav_items_for(scope)
      sections = Enum.map(items, &elem(&1, 0))

      assert "admin" in sections
    end

    test "includes admin tab for workspace owner scope" do
      scope = %Scope{admin?: false, settings_user: %{billing_role: "owner"}, privileges: []}
      items = Helpers.nav_items_for(scope)
      sections = Enum.map(items, &elem(&1, 0))

      assert "admin" in sections
    end

    test "includes admin tab for workspace billing admin scope" do
      scope = %Scope{admin?: false, settings_user: %{billing_role: "admin"}, privileges: []}
      items = Helpers.nav_items_for(scope)
      sections = Enum.map(items, &elem(&1, 0))

      assert "admin" in sections
    end

    test "excludes admin tab for regular member scope" do
      scope = %Scope{admin?: false, settings_user: %{billing_role: "member"}, privileges: []}
      items = Helpers.nav_items_for(scope)
      sections = Enum.map(items, &elem(&1, 0))

      refute "admin" in sections
    end

    test "excludes admin tab for nil billing_role scope" do
      scope = %Scope{admin?: false, settings_user: %{billing_role: nil}, privileges: []}
      items = Helpers.nav_items_for(scope)
      sections = Enum.map(items, &elem(&1, 0))

      refute "admin" in sections
    end

    test "always includes core sections" do
      scope = %Scope{admin?: false, settings_user: %{billing_role: "member"}, privileges: []}
      items = Helpers.nav_items_for(scope)
      sections = Enum.map(items, &elem(&1, 0))

      assert "profile" in sections
      assert "workspace" in sections
      assert "help" in sections
    end
  end

  describe "nav_items_for/1 with boolean" do
    test "includes admin tab when true" do
      items = Helpers.nav_items_for(true)
      sections = Enum.map(items, &elem(&1, 0))

      assert "admin" in sections
    end

    test "excludes admin tab when false" do
      items = Helpers.nav_items_for(false)
      sections = Enum.map(items, &elem(&1, 0))

      refute "admin" in sections
    end
  end
end
