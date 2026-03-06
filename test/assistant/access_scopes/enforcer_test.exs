defmodule Assistant.AccessScopes.EnforcerTest do
  use Assistant.DataCase, async: true

  alias Assistant.AccessScopes.Enforcer

  import Assistant.AccountsFixtures

  # ──────────────────────────────────────────────
  # Helpers
  # ──────────────────────────────────────────────

  defp create_linked_settings_user(attrs \\ %{}) do
    settings_user = settings_user_fixture(attrs)
    user = create_chat_user()

    settings_user
    |> Ecto.Changeset.change(user_id: user.id)
    |> Repo.update!()

    {user, Repo.get!(Assistant.Accounts.SettingsUser, settings_user.id)}
  end

  defp create_chat_user do
    {:ok, user} =
      %Assistant.Schemas.User{}
      |> Assistant.Schemas.User.changeset(%{
        external_id: "test-#{System.unique_integer([:positive])}",
        channel: "test"
      })
      |> Repo.insert()

    user
  end

  defp set_scopes(settings_user, scopes) do
    settings_user
    |> Ecto.Changeset.change(access_scopes: scopes)
    |> Repo.update!()
  end

  defp set_admin(settings_user, is_admin) do
    settings_user
    |> Ecto.Changeset.change(is_admin: is_admin)
    |> Repo.update!()
  end

  # ──────────────────────────────────────────────
  # P0: nil/unknown user_id => allow
  # ──────────────────────────────────────────────

  describe "skill_allowed?/2 with nil/unknown user_id" do
    test "allows nil user_id" do
      assert Enforcer.skill_allowed?(nil, "email.send")
    end

    test "allows \"unknown\" user_id" do
      assert Enforcer.skill_allowed?("unknown", "email.send")
    end
  end

  # ──────────────────────────────────────────────
  # P0: No linked settings_user => allow
  # ──────────────────────────────────────────────

  describe "skill_allowed?/2 with no linked settings_user" do
    test "allows when user_id has no linked settings_user" do
      user = create_chat_user()
      assert Enforcer.skill_allowed?(user.id, "email.send")
    end
  end

  # ──────────────────────────────────────────────
  # P0: Admin => always allow
  # ──────────────────────────────────────────────

  describe "skill_allowed?/2 with admin user" do
    test "admin bypasses all scope checks" do
      {user, settings_user} = create_linked_settings_user()
      set_admin(settings_user, true)
      set_scopes(settings_user, [])

      assert Enforcer.skill_allowed?(user.id, "email.send")
      assert Enforcer.skill_allowed?(user.id, "workflow.create")
      assert Enforcer.skill_allowed?(user.id, "memory.search")
    end

    test "admin with restricted scopes still allowed" do
      {user, settings_user} = create_linked_settings_user()
      set_admin(settings_user, true)
      set_scopes(settings_user, ["chat"])

      assert Enforcer.skill_allowed?(user.id, "email.send")
    end
  end

  # ──────────────────────────────────────────────
  # P0: Empty scopes => unrestricted
  # ──────────────────────────────────────────────

  describe "skill_allowed?/2 with empty scopes" do
    test "empty scopes means unrestricted access" do
      {user, settings_user} = create_linked_settings_user()
      set_scopes(settings_user, [])

      assert Enforcer.skill_allowed?(user.id, "email.send")
      assert Enforcer.skill_allowed?(user.id, "workflow.create")
      assert Enforcer.skill_allowed?(user.id, "memory.search")
      assert Enforcer.skill_allowed?(user.id, "agents.dispatch")
    end

    test "default scopes (empty array from DB) means unrestricted" do
      # access_scopes column defaults to {} (empty array) with NOT NULL constraint.
      # A freshly-created settings_user has [] scopes => unrestricted.
      {user, _settings_user} = create_linked_settings_user()

      assert Enforcer.skill_allowed?(user.id, "email.send")
      assert Enforcer.skill_allowed?(user.id, "workflow.create")
    end
  end

  # ──────────────────────────────────────────────
  # P0: Scope enforcement blocks/allows skills
  # ──────────────────────────────────────────────

  describe "skill_allowed?/2 with scoped user" do
    test "allows skill when user has matching scope" do
      {user, settings_user} = create_linked_settings_user()
      set_scopes(settings_user, ["integrations"])

      assert Enforcer.skill_allowed?(user.id, "email.send")
      assert Enforcer.skill_allowed?(user.id, "calendar.list")
      assert Enforcer.skill_allowed?(user.id, "files.search")
      assert Enforcer.skill_allowed?(user.id, "hubspot.contacts.list")
    end

    test "blocks skill when user lacks matching scope" do
      {user, settings_user} = create_linked_settings_user()
      set_scopes(settings_user, ["chat"])

      refute Enforcer.skill_allowed?(user.id, "email.send")
      refute Enforcer.skill_allowed?(user.id, "workflow.create")
      refute Enforcer.skill_allowed?(user.id, "memory.search")
    end

    test "chat scope grants access to chat-domain skills" do
      {user, settings_user} = create_linked_settings_user()
      set_scopes(settings_user, ["chat"])

      assert Enforcer.skill_allowed?(user.id, "agents.dispatch")
      assert Enforcer.skill_allowed?(user.id, "tasks.create")
      assert Enforcer.skill_allowed?(user.id, "web.search")
      assert Enforcer.skill_allowed?(user.id, "images.generate")
    end

    test "workflows scope grants access to workflow skills" do
      {user, settings_user} = create_linked_settings_user()
      set_scopes(settings_user, ["workflows"])

      assert Enforcer.skill_allowed?(user.id, "workflow.create")
      assert Enforcer.skill_allowed?(user.id, "workflow.list")
    end

    test "memory scope grants access to memory skills" do
      {user, settings_user} = create_linked_settings_user()
      set_scopes(settings_user, ["memory"])

      assert Enforcer.skill_allowed?(user.id, "memory.search")
      assert Enforcer.skill_allowed?(user.id, "memory.save")
    end

    test "multiple scopes grant access to all matching domains" do
      {user, settings_user} = create_linked_settings_user()
      set_scopes(settings_user, ["chat", "integrations", "workflows"])

      assert Enforcer.skill_allowed?(user.id, "agents.dispatch")
      assert Enforcer.skill_allowed?(user.id, "email.send")
      assert Enforcer.skill_allowed?(user.id, "workflow.create")
      refute Enforcer.skill_allowed?(user.id, "memory.search")
    end
  end

  # ──────────────────────────────────────────────
  # P1: Edge cases — unknown domains
  # ──────────────────────────────────────────────

  describe "skill_allowed?/2 with unknown domains" do
    test "skill with unmapped domain is denied (default-deny for unmapped)" do
      {user, settings_user} = create_linked_settings_user()
      set_scopes(settings_user, ["chat"])

      # Unknown domain doesn't map to any scope => denied (default-deny)
      refute Enforcer.skill_allowed?(user.id, "unknown.action")
    end

    test "skill without dot separator is denied (default-deny for unmapped)" do
      {user, settings_user} = create_linked_settings_user()
      set_scopes(settings_user, ["chat"])

      # No domain extracted => nil domain => nil scope => denied (default-deny)
      refute Enforcer.skill_allowed?(user.id, "standalone_skill")
    end
  end
end
