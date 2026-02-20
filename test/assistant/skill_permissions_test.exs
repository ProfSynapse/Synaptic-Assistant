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
