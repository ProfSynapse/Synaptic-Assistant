defmodule Assistant.UserSkillOverridesTest do
  @moduledoc """
  Tests for the UserSkillOverrides context module.

  Covers: enabled_for_user?, set_enabled (create + upsert), clear_override,
  list_for_user, and overrides_map_for_user.
  """
  use Assistant.DataCase, async: false

  alias Assistant.UserSkillOverrides

  setup do
    {:ok, user} =
      %Assistant.Schemas.User{}
      |> Assistant.Schemas.User.changeset(%{
        external_id: "uso-test-#{System.unique_integer([:positive])}",
        channel: "test",
        display_name: "USO Test User"
      })
      |> Repo.insert()

    %{user_id: user.id}
  end

  describe "enabled_for_user?/2" do
    test "returns true (default) when no override exists", %{user_id: user_id} do
      assert UserSkillOverrides.enabled_for_user?(user_id, "email.send") == true
    end

    test "returns false when disabled override exists", %{user_id: user_id} do
      {:ok, _} = UserSkillOverrides.set_enabled(user_id, "email.send", false)
      assert UserSkillOverrides.enabled_for_user?(user_id, "email.send") == false
    end

    test "returns true when enabled override exists", %{user_id: user_id} do
      {:ok, _} = UserSkillOverrides.set_enabled(user_id, "email.send", true)
      assert UserSkillOverrides.enabled_for_user?(user_id, "email.send") == true
    end

    test "returns default when user_id is nil" do
      assert UserSkillOverrides.enabled_for_user?(nil, "email.send") == true
    end

    test "returns default when user_id is empty string" do
      assert UserSkillOverrides.enabled_for_user?("", "email.send") == true
    end

    test "returns false when skill_name is nil", %{user_id: user_id} do
      assert UserSkillOverrides.enabled_for_user?(user_id, nil) == false
    end

    test "returns false when skill_name is empty string", %{user_id: user_id} do
      assert UserSkillOverrides.enabled_for_user?(user_id, "") == false
    end

    test "respects :default option", %{user_id: user_id} do
      assert UserSkillOverrides.enabled_for_user?(user_id, "email.send", default: false) == false
    end
  end

  describe "set_enabled/3" do
    test "creates a new override", %{user_id: user_id} do
      assert {:ok, override} = UserSkillOverrides.set_enabled(user_id, "email.send", false)
      assert override.user_id == user_id
      assert override.skill_name == "email.send"
      assert override.enabled == false
    end

    test "upserts existing override", %{user_id: user_id} do
      {:ok, _} = UserSkillOverrides.set_enabled(user_id, "email.send", false)
      assert UserSkillOverrides.enabled_for_user?(user_id, "email.send") == false

      {:ok, _} = UserSkillOverrides.set_enabled(user_id, "email.send", true)
      assert UserSkillOverrides.enabled_for_user?(user_id, "email.send") == true
    end

    test "trims skill_name whitespace", %{user_id: user_id} do
      {:ok, override} = UserSkillOverrides.set_enabled(user_id, "  email.send  ", false)
      assert override.skill_name == "email.send"
    end

    test "returns error for invalid arguments" do
      assert UserSkillOverrides.set_enabled(nil, "email.send", false) == {:error, :invalid}
      assert UserSkillOverrides.set_enabled("uid", nil, false) == {:error, :invalid}
      assert UserSkillOverrides.set_enabled("uid", "email.send", "yes") == {:error, :invalid}
    end
  end

  describe "clear_override/2" do
    test "removes an existing override", %{user_id: user_id} do
      {:ok, _} = UserSkillOverrides.set_enabled(user_id, "email.send", false)
      assert UserSkillOverrides.enabled_for_user?(user_id, "email.send") == false

      assert :ok = UserSkillOverrides.clear_override(user_id, "email.send")
      assert UserSkillOverrides.enabled_for_user?(user_id, "email.send") == true
    end

    test "returns :ok when no override exists", %{user_id: user_id} do
      assert :ok = UserSkillOverrides.clear_override(user_id, "email.send")
    end

    test "returns :ok for invalid arguments" do
      assert :ok = UserSkillOverrides.clear_override(nil, "email.send")
      assert :ok = UserSkillOverrides.clear_override("uid", nil)
    end
  end

  describe "list_for_user/1" do
    test "returns empty list when no overrides", %{user_id: user_id} do
      assert UserSkillOverrides.list_for_user(user_id) == []
    end

    test "returns overrides sorted by skill_name", %{user_id: user_id} do
      {:ok, _} = UserSkillOverrides.set_enabled(user_id, "email.send", false)
      {:ok, _} = UserSkillOverrides.set_enabled(user_id, "calendar.create", true)

      overrides = UserSkillOverrides.list_for_user(user_id)
      names = Enum.map(overrides, & &1.skill_name)
      assert names == ["calendar.create", "email.send"]
    end

    test "returns empty list for nil user_id" do
      assert UserSkillOverrides.list_for_user(nil) == []
    end
  end

  describe "overrides_map_for_user/1" do
    test "returns map of skill_name => enabled", %{user_id: user_id} do
      {:ok, _} = UserSkillOverrides.set_enabled(user_id, "email.send", false)
      {:ok, _} = UserSkillOverrides.set_enabled(user_id, "calendar.create", true)

      map = UserSkillOverrides.overrides_map_for_user(user_id)
      assert map == %{"email.send" => false, "calendar.create" => true}
    end

    test "returns empty map when no overrides", %{user_id: user_id} do
      assert UserSkillOverrides.overrides_map_for_user(user_id) == %{}
    end

    test "returns empty map for nil user_id" do
      assert UserSkillOverrides.overrides_map_for_user(nil) == %{}
    end
  end
end
