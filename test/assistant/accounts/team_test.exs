defmodule Assistant.Accounts.TeamTest do
  use Assistant.DataCase, async: false

  import Assistant.AccountsFixtures

  alias Assistant.Accounts
  alias Assistant.Accounts.Team

  describe "teams" do
    test "create_team/1 creates a team" do
      assert {:ok, %Team{name: "Marketing"}} =
               Accounts.create_team(%{name: "Marketing", description: "Marketing team"})
    end

    test "create_team/1 validates name uniqueness" do
      Accounts.create_team(%{name: "Sales"})
      assert {:error, changeset} = Accounts.create_team(%{name: "Sales"})
      assert "has already been taken" in errors_on(changeset).name
    end

    test "create_team/1 validates name format" do
      assert {:error, changeset} = Accounts.create_team(%{name: ""})
      assert errors_on(changeset).name != []
    end

    test "list_teams/0 returns all teams" do
      {:ok, _} = Accounts.create_team(%{name: "Alpha"})
      {:ok, _} = Accounts.create_team(%{name: "Beta"})

      teams = Accounts.list_teams()
      assert length(teams) == 2
      assert Enum.map(teams, & &1.name) == ["Alpha", "Beta"]
    end

    test "delete_team/1 removes the team" do
      {:ok, team} = Accounts.create_team(%{name: "Temp"})
      assert {:ok, _} = Accounts.delete_team(team)
      assert Accounts.get_team(team.id) == nil
    end

    test "assign_user_to_team/2 sets team_id on user" do
      {:ok, team} = Accounts.create_team(%{name: "DevTeam"})
      user = settings_user_fixture()

      assert {:ok, updated} = Accounts.assign_user_to_team(user.id, team.id)
      assert updated.team_id == team.id
    end

    test "assign_user_to_team/2 with nil removes team" do
      {:ok, team} = Accounts.create_team(%{name: "DevTeam2"})
      user = settings_user_fixture()
      Accounts.assign_user_to_team(user.id, team.id)

      assert {:ok, updated} = Accounts.assign_user_to_team(user.id, nil)
      assert updated.team_id == nil
    end
  end

  describe "super_admin" do
    test "bootstrap_admin_access sets is_super_admin" do
      user = settings_user_fixture()
      {:ok, admin} = Accounts.bootstrap_admin_access(user)

      assert admin.is_admin == true
      assert admin.is_super_admin == true
    end

    test "toggle_admin_status requires super_admin actor" do
      user = settings_user_fixture()
      {:ok, super_admin} = Accounts.bootstrap_admin_access(user)

      target = settings_user_fixture()

      # Non-super admin actor
      regular_admin =
        settings_user_fixture()
        |> Ecto.Changeset.change(is_admin: true)
        |> Repo.update!()

      assert {:error, :not_authorized} =
               Accounts.toggle_admin_status(target.id, true, regular_admin)

      # Super admin actor succeeds
      assert {:ok, _} = Accounts.toggle_admin_status(target.id, true, super_admin)
    end

    test "toggle_admin_status cannot modify super_admin" do
      user = settings_user_fixture()
      {:ok, super_admin} = Accounts.bootstrap_admin_access(user)

      assert {:error, :cannot_modify_super_admin} =
               Accounts.toggle_admin_status(super_admin.id, false, super_admin)
    end
  end

  describe "team-scoped user listing" do
    test "list_settings_users_for_admin with team_id filters by team" do
      {:ok, team_a} = Accounts.create_team(%{name: "TeamA"})
      {:ok, team_b} = Accounts.create_team(%{name: "TeamB"})

      user_a = settings_user_fixture()
      user_b = settings_user_fixture()

      Accounts.assign_user_to_team(user_a.id, team_a.id)
      Accounts.assign_user_to_team(user_b.id, team_b.id)

      users_a = Accounts.list_settings_users_for_admin(team_id: team_a.id)
      assert length(users_a) == 1
      assert hd(users_a).id == user_a.id

      # No filter returns all
      all = Accounts.list_settings_users_for_admin()
      assert length(all) >= 2
    end
  end
end
