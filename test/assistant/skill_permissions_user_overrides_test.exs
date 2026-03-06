defmodule Assistant.SkillPermissionsUserOverridesTest do
  use Assistant.DataCase, async: false

  import Assistant.ChannelFixtures

  alias Assistant.SettingsUserConnectorStates
  alias Assistant.SkillPermissions

  setup do
    permissions_path =
      Path.join(
        System.tmp_dir!(),
        "skill_perms_user_overrides_#{System.unique_integer([:positive])}.json"
      )

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

    :ok
  end

  describe "enabled_for_user?/2" do
    test "applies per-user overrides without affecting other users" do
      user_a = chat_user_fixture()
      user_b = chat_user_fixture()

      assert SkillPermissions.enabled_for_user?(user_a.id, "email.send")
      assert SkillPermissions.enabled_for_user?(user_b.id, "email.send")

      {:ok, _override} = SkillPermissions.set_enabled_for_user(user_a.id, "email.send", false)

      refute SkillPermissions.enabled_for_user?(user_a.id, "email.send")
      assert SkillPermissions.enabled_for_user?(user_b.id, "email.send")
    end

    test "global hard deny still blocks a user-enabled skill" do
      user = chat_user_fixture()

      File.write!(
        Application.fetch_env!(:assistant, :skill_permissions_path),
        ~s({"email.send":false})
      )

      {:ok, _override} = SkillPermissions.set_enabled_for_user(user.id, "email.send", true)

      refute SkillPermissions.enabled_for_user?(user.id, "email.send")
    end

    test "hubspot skills require connector state to be enabled for the user" do
      user = chat_user_fixture()
      skill = "hubspot.search_contacts"

      refute SkillPermissions.enabled_for_user?(user.id, skill)

      {:ok, _state} =
        SettingsUserConnectorStates.set_enabled_for_user(user.id, "hubspot", false)

      refute SkillPermissions.enabled_for_user?(user.id, skill)

      {:ok, _state} =
        SettingsUserConnectorStates.set_enabled_for_user(user.id, "hubspot", true)

      assert SkillPermissions.enabled_for_user?(user.id, skill)
    end
  end
end
