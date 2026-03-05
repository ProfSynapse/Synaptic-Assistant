defmodule Assistant.SettingsUserConnectorStatesTest do
  @moduledoc """
  Tests for the SettingsUserConnectorStates context module.

  Covers: enabled_for_user?, set_enabled_for_user (create + upsert),
  clear_for_user, list_for_user, get_for_user, and Registry.groups() validation.
  """
  use Assistant.DataCase, async: false

  alias Assistant.SettingsUserConnectorStates

  setup do
    {:ok, user} =
      %Assistant.Schemas.User{}
      |> Assistant.Schemas.User.changeset(%{
        external_id: "sucs-test-#{System.unique_integer([:positive])}",
        channel: "test",
        display_name: "SUCS Test User"
      })
      |> Repo.insert()

    %{user_id: user.id}
  end

  describe "enabled_for_user?/3" do
    test "returns true (default) when no state exists", %{user_id: user_id} do
      assert SettingsUserConnectorStates.enabled_for_user?(user_id, "hubspot") == true
    end

    test "returns false when disabled state exists", %{user_id: user_id} do
      {:ok, _} = SettingsUserConnectorStates.set_enabled_for_user(user_id, "hubspot", false)
      assert SettingsUserConnectorStates.enabled_for_user?(user_id, "hubspot") == false
    end

    test "returns true when enabled state exists", %{user_id: user_id} do
      {:ok, _} = SettingsUserConnectorStates.set_enabled_for_user(user_id, "hubspot", true)
      assert SettingsUserConnectorStates.enabled_for_user?(user_id, "hubspot") == true
    end

    test "returns default when user_id is nil" do
      assert SettingsUserConnectorStates.enabled_for_user?(nil, "hubspot") == true
    end

    test "returns default when user_id is empty string" do
      assert SettingsUserConnectorStates.enabled_for_user?("", "hubspot") == true
    end

    test "returns default when integration_group is nil", %{user_id: user_id} do
      assert SettingsUserConnectorStates.enabled_for_user?(user_id, nil) == true
    end

    test "returns default when integration_group is empty string", %{user_id: user_id} do
      assert SettingsUserConnectorStates.enabled_for_user?(user_id, "") == true
    end

    test "respects :default option", %{user_id: user_id} do
      assert SettingsUserConnectorStates.enabled_for_user?(user_id, "hubspot", default: false) ==
               false
    end
  end

  describe "set_enabled_for_user/4" do
    test "creates a new state", %{user_id: user_id} do
      assert {:ok, state} =
               SettingsUserConnectorStates.set_enabled_for_user(user_id, "hubspot", true)

      assert state.user_id == user_id
      assert state.integration_group == "hubspot"
      assert state.enabled == true
      assert state.connected_at != nil
      assert state.disconnected_at == nil
    end

    test "sets disconnected_at when disabling", %{user_id: user_id} do
      assert {:ok, state} =
               SettingsUserConnectorStates.set_enabled_for_user(user_id, "hubspot", false)

      assert state.enabled == false
      assert state.connected_at == nil
      assert state.disconnected_at != nil
    end

    test "upserts existing state", %{user_id: user_id} do
      {:ok, _} = SettingsUserConnectorStates.set_enabled_for_user(user_id, "hubspot", true)
      assert SettingsUserConnectorStates.enabled_for_user?(user_id, "hubspot") == true

      {:ok, _} = SettingsUserConnectorStates.set_enabled_for_user(user_id, "hubspot", false)
      assert SettingsUserConnectorStates.enabled_for_user?(user_id, "hubspot") == false
    end

    test "accepts metadata map", %{user_id: user_id} do
      metadata = %{"portal_id" => "12345"}

      {:ok, state} =
        SettingsUserConnectorStates.set_enabled_for_user(user_id, "hubspot", true, metadata)

      assert state.metadata == metadata
    end

    test "validates against Registry.groups — rejects unknown integration_group", %{
      user_id: user_id
    } do
      assert {:error, changeset} =
               SettingsUserConnectorStates.set_enabled_for_user(
                 user_id,
                 "nonexistent_integration",
                 true
               )

      assert errors_on(changeset).integration_group == ["is not a recognized integration group"]
    end

    test "accepts known integration groups", %{user_id: user_id} do
      # "telegram" is in Registry.groups()
      assert {:ok, state} =
               SettingsUserConnectorStates.set_enabled_for_user(user_id, "telegram", true)

      assert state.integration_group == "telegram"
    end

    test "returns error for invalid arguments" do
      assert SettingsUserConnectorStates.set_enabled_for_user(nil, "hubspot", true) ==
               {:error, :invalid}

      assert SettingsUserConnectorStates.set_enabled_for_user("uid", nil, true) ==
               {:error, :invalid}

      assert SettingsUserConnectorStates.set_enabled_for_user("uid", "hubspot", "yes") ==
               {:error, :invalid}
    end
  end

  describe "clear_for_user/2" do
    test "removes an existing state", %{user_id: user_id} do
      {:ok, _} = SettingsUserConnectorStates.set_enabled_for_user(user_id, "hubspot", false)
      assert SettingsUserConnectorStates.enabled_for_user?(user_id, "hubspot") == false

      assert :ok = SettingsUserConnectorStates.clear_for_user(user_id, "hubspot")
      assert SettingsUserConnectorStates.enabled_for_user?(user_id, "hubspot") == true
    end

    test "returns :ok when no state exists", %{user_id: user_id} do
      assert :ok = SettingsUserConnectorStates.clear_for_user(user_id, "hubspot")
    end

    test "returns :ok for invalid arguments" do
      assert :ok = SettingsUserConnectorStates.clear_for_user(nil, "hubspot")
      assert :ok = SettingsUserConnectorStates.clear_for_user("uid", nil)
    end
  end

  describe "list_for_user/1" do
    test "returns empty list when no states exist", %{user_id: user_id} do
      assert SettingsUserConnectorStates.list_for_user(user_id) == []
    end

    test "returns states sorted by integration_group", %{user_id: user_id} do
      {:ok, _} = SettingsUserConnectorStates.set_enabled_for_user(user_id, "telegram", true)
      {:ok, _} = SettingsUserConnectorStates.set_enabled_for_user(user_id, "hubspot", false)

      states = SettingsUserConnectorStates.list_for_user(user_id)
      groups = Enum.map(states, & &1.integration_group)
      assert groups == ["hubspot", "telegram"]
    end

    test "returns empty list for nil user_id" do
      assert SettingsUserConnectorStates.list_for_user(nil) == []
    end
  end

  describe "get_for_user/2" do
    test "returns {:ok, state} when state exists", %{user_id: user_id} do
      {:ok, _} = SettingsUserConnectorStates.set_enabled_for_user(user_id, "hubspot", true)
      assert {:ok, state} = SettingsUserConnectorStates.get_for_user(user_id, "hubspot")
      assert state.integration_group == "hubspot"
      assert state.enabled == true
    end

    test "returns {:error, :not_found} when no state exists", %{user_id: user_id} do
      assert {:error, :not_found} =
               SettingsUserConnectorStates.get_for_user(user_id, "hubspot")
    end

    test "returns {:error, :not_found} for invalid arguments" do
      assert {:error, :not_found} = SettingsUserConnectorStates.get_for_user(nil, "hubspot")
      assert {:error, :not_found} = SettingsUserConnectorStates.get_for_user("uid", nil)
    end
  end
end
