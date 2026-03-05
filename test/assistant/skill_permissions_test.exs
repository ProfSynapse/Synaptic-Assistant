# test/assistant/skill_permissions_test.exs — Regression tests for SkillPermissions.
#
# Bug 1 regression: enabled?(nil) crashed with FunctionClauseError because the
# guard `when is_binary(skill_name)` rejected nil. After fix, nil and other
# non-binary inputs return false instead of crashing.

defmodule Assistant.SkillPermissionsTest do
  use ExUnit.Case, async: true

  alias Assistant.SkillPermissions

  # Use a temp permissions file to avoid touching the real one
  setup do
    tmp_dir = System.tmp_dir!()

    permissions_path =
      Path.join(tmp_dir, "skill_perms_test_#{System.unique_integer([:positive])}.json")

    # Configure the app to use our temp path
    previous = Application.get_env(:assistant, :skill_permissions_path)
    Application.put_env(:assistant, :skill_permissions_path, permissions_path)

    on_exit(fn ->
      File.rm(permissions_path)

      if previous do
        Application.put_env(:assistant, :skill_permissions_path, previous)
      else
        Application.delete_env(:assistant, :skill_permissions_path)
      end
    end)

    %{permissions_path: permissions_path}
  end

  # ---------------------------------------------------------------
  # Bug 1 regression: enabled?(nil) should not crash
  # ---------------------------------------------------------------

  describe "enabled?/1 with nil input (Bug 1 regression)" do
    test "returns false for nil skill_name" do
      # This was the original crash: FunctionClauseError when nil passed
      assert SkillPermissions.enabled?(nil) == false
    end

    test "does not crash for empty string" do
      # Empty string is a valid binary, handled by the normal code path
      # (defaults to true since no skill has an empty name in overrides)
      result = SkillPermissions.enabled?("")
      assert is_boolean(result)
    end

    test "returns false for non-string types" do
      assert SkillPermissions.enabled?(123) == false
      assert SkillPermissions.enabled?(:atom) == false
      assert SkillPermissions.enabled?([]) == false
    end
  end

  # ---------------------------------------------------------------
  # enabled?/1 normal behavior (ensures fix doesn't break happy path)
  # ---------------------------------------------------------------

  describe "enabled?/1 normal behavior" do
    test "returns true for unknown skill (default is enabled)" do
      assert SkillPermissions.enabled?("some.skill") == true
    end

    test "returns false for explicitly disabled skill", %{permissions_path: path} do
      File.write!(path, Jason.encode!(%{"email.send" => false}))
      assert SkillPermissions.enabled?("email.send") == false
    end

    test "returns true for explicitly enabled skill", %{permissions_path: path} do
      File.write!(path, Jason.encode!(%{"email.send" => true}))
      assert SkillPermissions.enabled?("email.send") == true
    end
  end

  # ---------------------------------------------------------------
  # skill_label/1 and domain_label/1
  # ---------------------------------------------------------------

  describe "skill_label/1" do
    test "extracts and capitalizes action from dotted name" do
      assert SkillPermissions.skill_label("email.send_draft") == "Send Draft"
    end

    test "returns full name when no dot separator" do
      assert SkillPermissions.skill_label("standalone") == "standalone"
    end
  end

  describe "domain_label/1" do
    test "capitalizes domain with underscores" do
      assert SkillPermissions.domain_label("task_manager") == "Task Manager"
    end
  end
end

defmodule Assistant.SkillPermissions.EnabledForUserTest do
  @moduledoc """
  Tests for the 3-layer gate logic in SkillPermissions.enabled_for_user?/2.

  The function checks: global_enabled AND user_enabled AND connector_enabled.
  Uses DataCase because user_enabled and connector_enabled query the DB.
  """
  use Assistant.DataCase, async: false

  alias Assistant.SkillPermissions
  alias Assistant.UserSkillOverrides
  alias Assistant.SettingsUserConnectorStates

  # Use a temp permissions file for the global gate
  setup do
    tmp_dir = System.tmp_dir!()

    permissions_path =
      Path.join(tmp_dir, "skill_perms_gate_test_#{System.unique_integer([:positive])}.json")

    previous = Application.get_env(:assistant, :skill_permissions_path)
    Application.put_env(:assistant, :skill_permissions_path, permissions_path)

    # Create a user for per-user tests (external_id is NOT NULL in the DB)
    {:ok, user} =
      %Assistant.Schemas.User{}
      |> Assistant.Schemas.User.changeset(%{
        external_id: "gate-test-#{System.unique_integer([:positive])}",
        channel: "test",
        display_name: "Gate Test User"
      })
      |> Repo.insert()

    on_exit(fn ->
      File.rm(permissions_path)

      if previous do
        Application.put_env(:assistant, :skill_permissions_path, previous)
      else
        Application.delete_env(:assistant, :skill_permissions_path)
      end
    end)

    %{permissions_path: permissions_path, user_id: user.id}
  end

  describe "3-layer gate: all enabled" do
    test "returns true when global enabled, no user override, non-hubspot skill", %{user_id: user_id} do
      assert SkillPermissions.enabled_for_user?(user_id, "email.send") == true
    end

    test "returns true when global enabled and user override is explicitly true", %{
      user_id: user_id
    } do
      {:ok, _} = UserSkillOverrides.set_enabled(user_id, "email.send", true)
      assert SkillPermissions.enabled_for_user?(user_id, "email.send") == true
    end
  end

  describe "3-layer gate: global gate" do
    test "returns false when global disabled regardless of user override", %{
      permissions_path: path,
      user_id: user_id
    } do
      File.write!(path, Jason.encode!(%{"email.send" => false}))

      # Even with an explicit user enable, global gate blocks
      {:ok, _} = UserSkillOverrides.set_enabled(user_id, "email.send", true)
      assert SkillPermissions.enabled_for_user?(user_id, "email.send") == false
    end

    test "returns false when global disabled and no user override", %{
      permissions_path: path,
      user_id: user_id
    } do
      File.write!(path, Jason.encode!(%{"calendar.create" => false}))
      assert SkillPermissions.enabled_for_user?(user_id, "calendar.create") == false
    end
  end

  describe "3-layer gate: user override gate" do
    test "returns false when user override disables the skill", %{user_id: user_id} do
      {:ok, _} = UserSkillOverrides.set_enabled(user_id, "email.send", false)
      assert SkillPermissions.enabled_for_user?(user_id, "email.send") == false
    end

    test "returns true when no user override exists (defaults to true)", %{user_id: user_id} do
      assert SkillPermissions.enabled_for_user?(user_id, "email.send") == true
    end

    test "clearing user override reverts to default true", %{user_id: user_id} do
      {:ok, _} = UserSkillOverrides.set_enabled(user_id, "email.send", false)
      assert SkillPermissions.enabled_for_user?(user_id, "email.send") == false

      :ok = UserSkillOverrides.clear_override(user_id, "email.send")
      assert SkillPermissions.enabled_for_user?(user_id, "email.send") == true
    end
  end

  describe "3-layer gate: connector gate" do
    test "hubspot skill returns false when connector disabled for user", %{user_id: user_id} do
      {:ok, _} =
        SettingsUserConnectorStates.set_enabled_for_user(user_id, "hubspot", false)

      assert SkillPermissions.enabled_for_user?(user_id, "hubspot.search_contacts") == false
    end

    test "hubspot skill returns true when connector enabled for user", %{user_id: user_id} do
      {:ok, _} =
        SettingsUserConnectorStates.set_enabled_for_user(user_id, "hubspot", true)

      assert SkillPermissions.enabled_for_user?(user_id, "hubspot.search_contacts") == true
    end

    test "hubspot skill returns true when no connector state exists (default)", %{
      user_id: user_id
    } do
      assert SkillPermissions.enabled_for_user?(user_id, "hubspot.search_contacts") == true
    end

    test "non-hubspot skill ignores connector gate entirely", %{user_id: user_id} do
      # Even if hubspot connector is disabled, non-hubspot skills are unaffected
      {:ok, _} =
        SettingsUserConnectorStates.set_enabled_for_user(user_id, "hubspot", false)

      assert SkillPermissions.enabled_for_user?(user_id, "email.send") == true
    end
  end

  describe "3-layer gate: nil user_id" do
    test "nil user_id with global enabled returns true (user + connector default to true)" do
      assert SkillPermissions.enabled_for_user?(nil, "email.send") == true
    end

    test "nil user_id with global disabled returns false", %{permissions_path: path} do
      File.write!(path, Jason.encode!(%{"email.send" => false}))
      assert SkillPermissions.enabled_for_user?(nil, "email.send") == false
    end

    test "nil user_id for hubspot skill returns true (connector defaults to true)" do
      assert SkillPermissions.enabled_for_user?(nil, "hubspot.search_contacts") == true
    end
  end

  describe "3-layer gate: invalid inputs" do
    test "non-binary skill_name returns false" do
      assert SkillPermissions.enabled_for_user?("some-user-id", nil) == false
      assert SkillPermissions.enabled_for_user?("some-user-id", 123) == false
    end

    test "set_enabled_for_user with invalid args returns error" do
      assert SkillPermissions.set_enabled_for_user(nil, "email.send", true) == {:error, :invalid}
      assert SkillPermissions.set_enabled_for_user("uid", nil, true) == {:error, :invalid}
    end

    test "clear_user_override with invalid args returns :ok" do
      assert SkillPermissions.clear_user_override(nil, "email.send") == :ok
      assert SkillPermissions.clear_user_override("uid", nil) == :ok
    end
  end
end
