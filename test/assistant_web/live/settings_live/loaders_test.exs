defmodule AssistantWeb.SettingsLive.LoadersTest do
  use ExUnit.Case, async: true

  alias AssistantWeb.SettingsLive.Loaders

  # ──────────────────────────────────────────────
  # filter_admin_users/2 — pure function tests
  # ──────────────────────────────────────────────

  describe "filter_admin_users/2" do
    @users [
      %{email: "alice@example.com", display_name: "Alice Admin"},
      %{email: "bob@example.com", display_name: "Bob Builder"},
      %{email: "carol@example.com", display_name: nil},
      %{email: "dave@EXAMPLE.COM", display_name: "Dave Dev"}
    ]

    test "returns all users when query is empty string" do
      assert Loaders.filter_admin_users(@users, "") == @users
    end

    test "returns all users when query is nil" do
      assert Loaders.filter_admin_users(@users, nil) == @users
    end

    test "returns all users when query is whitespace only" do
      assert Loaders.filter_admin_users(@users, "   ") == @users
    end

    test "filters by email substring" do
      result = Loaders.filter_admin_users(@users, "alice")
      assert length(result) == 1
      assert hd(result).email == "alice@example.com"
    end

    test "filters by display_name substring" do
      result = Loaders.filter_admin_users(@users, "Builder")
      assert length(result) == 1
      assert hd(result).email == "bob@example.com"
    end

    test "is case-insensitive for email" do
      result = Loaders.filter_admin_users(@users, "ALICE")
      assert length(result) == 1
      assert hd(result).email == "alice@example.com"
    end

    test "is case-insensitive for display_name" do
      result = Loaders.filter_admin_users(@users, "alice admin")
      assert length(result) == 1
      assert hd(result).email == "alice@example.com"
    end

    test "handles nil display_name without error" do
      result = Loaders.filter_admin_users(@users, "carol")
      assert length(result) == 1
      assert hd(result).email == "carol@example.com"
    end

    test "matches partial email domain" do
      result = Loaders.filter_admin_users(@users, "example.com")
      assert length(result) == 4
    end

    test "returns empty list when no matches" do
      result = Loaders.filter_admin_users(@users, "zzz-nonexistent")
      assert result == []
    end

    test "matches multiple users" do
      result = Loaders.filter_admin_users(@users, "example")
      assert length(result) == 4
    end

    test "handles empty user list" do
      assert Loaders.filter_admin_users([], "anything") == []
    end

    test "trims query whitespace before matching" do
      result = Loaders.filter_admin_users(@users, "  alice  ")
      assert length(result) == 1
      assert hd(result).email == "alice@example.com"
    end
  end
end
