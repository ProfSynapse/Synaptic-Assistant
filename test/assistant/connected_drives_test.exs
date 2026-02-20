# test/assistant/connected_drives_test.exs
#
# Tests for ConnectedDrives context module — CRUD operations for user-connected
# Google Drives. Validates listing, connecting, toggling, disconnecting, and
# personal drive idempotency.
#
# Related files:
#   - lib/assistant/connected_drives.ex (module under test)
#   - lib/assistant/schemas/connected_drive.ex (schema)

defmodule Assistant.ConnectedDrivesTest do
  use Assistant.DataCase, async: true

  alias Assistant.ConnectedDrives
  alias Assistant.Schemas.ConnectedDrive

  # ---------------------------------------------------------------
  # Setup — create test users
  # ---------------------------------------------------------------

  setup do
    user = insert_test_user("cd-test")
    user2 = insert_test_user("cd-test-2")
    %{user: user, user2: user2}
  end

  defp insert_test_user(prefix) do
    %Assistant.Schemas.User{}
    |> Assistant.Schemas.User.changeset(%{
      external_id: "#{prefix}-#{System.unique_integer([:positive])}",
      channel: "test"
    })
    |> Repo.insert!()
  end

  # Insert a shared drive directly (bypasses connect/2 upsert which has
  # a known bug with partial unique indexes — see BUG note in connect tests)
  defp insert_shared_drive(user_id, drive_id, drive_name) do
    %ConnectedDrive{}
    |> ConnectedDrive.changeset(%{
      user_id: user_id,
      drive_id: drive_id,
      drive_name: drive_name,
      drive_type: "shared"
    })
    |> Repo.insert!()
  end

  # ---------------------------------------------------------------
  # list_for_user
  # ---------------------------------------------------------------

  describe "list_for_user/1" do
    test "returns empty list when no drives connected", %{user: user} do
      assert [] = ConnectedDrives.list_for_user(user.id)
    end

    test "returns connected drives ordered by type then name", %{user: user} do
      insert_shared_drive(user.id, "shared-z", "Z Drive")
      {:ok, _} = ConnectedDrives.ensure_personal_drive(user.id)
      insert_shared_drive(user.id, "shared-a", "A Drive")

      drives = ConnectedDrives.list_for_user(user.id)
      assert length(drives) == 3
      # Personal drives sort first (drive_type "personal" < "shared")
      assert hd(drives).drive_type == "personal"
      # Shared drives sorted by name
      shared = Enum.filter(drives, &(&1.drive_type == "shared"))
      assert Enum.map(shared, & &1.drive_name) == ["A Drive", "Z Drive"]
    end

    test "does not return other user's drives", %{user: user, user2: user2} do
      {:ok, _} = ConnectedDrives.ensure_personal_drive(user.id)
      {:ok, _} = ConnectedDrives.ensure_personal_drive(user2.id)

      assert length(ConnectedDrives.list_for_user(user.id)) == 1
      assert length(ConnectedDrives.list_for_user(user2.id)) == 1
    end
  end

  # ---------------------------------------------------------------
  # enabled_for_user
  # ---------------------------------------------------------------

  describe "enabled_for_user/1" do
    test "returns only enabled drives", %{user: user} do
      {:ok, personal} = ConnectedDrives.ensure_personal_drive(user.id)
      shared = insert_shared_drive(user.id, "shared-1", "Shared")

      # Disable the shared drive
      {:ok, _} = ConnectedDrives.toggle(shared.id, false)

      enabled = ConnectedDrives.enabled_for_user(user.id)
      assert length(enabled) == 1
      assert hd(enabled).id == personal.id
    end

    test "returns empty list when all drives disabled", %{user: user} do
      {:ok, personal} = ConnectedDrives.ensure_personal_drive(user.id)
      {:ok, _} = ConnectedDrives.toggle(personal.id, false)

      assert [] = ConnectedDrives.enabled_for_user(user.id)
    end
  end

  # ---------------------------------------------------------------
  # connect
  # ---------------------------------------------------------------

  describe "connect/2" do
    test "connects a shared drive", %{user: user} do
      assert {:ok, %ConnectedDrive{} = drive} =
               ConnectedDrives.connect(user.id, %{
                 drive_id: "shared-abc",
                 drive_name: "Team Drive",
                 drive_type: "shared"
               })

      assert drive.user_id == user.id
      assert drive.drive_id == "shared-abc"
      assert drive.drive_name == "Team Drive"
      assert drive.drive_type == "shared"
      assert drive.enabled == true
    end

    test "shared drive connect upserts on conflict (one row, name updated)", %{user: user} do
      attrs = %{drive_id: "shared-abc", drive_name: "Team Drive", drive_type: "shared"}

      {:ok, _first} = ConnectedDrives.connect(user.id, attrs)
      {:ok, _second} = ConnectedDrives.connect(user.id, %{attrs | drive_name: "Renamed Drive"})

      # Only one shared drive row should exist for this drive_id
      drives = ConnectedDrives.list_for_user(user.id)
      shared = Enum.filter(drives, &(&1.drive_id == "shared-abc"))
      assert length(shared) == 1
      assert hd(shared).drive_name == "Renamed Drive"
    end

    test "connects personal drive via ensure_personal_drive", %{user: user} do
      assert {:ok, %ConnectedDrive{} = drive} = ConnectedDrives.ensure_personal_drive(user.id)

      assert drive.user_id == user.id
      assert drive.drive_name == "My Drive"
      assert drive.drive_type == "personal"
      assert drive.enabled == true
    end

    test "rejects shared drive without drive_id", %{user: user} do
      assert {:error, changeset} =
               ConnectedDrives.connect(user.id, %{
                 drive_id: nil,
                 drive_name: "Bad Shared",
                 drive_type: "shared"
               })

      assert %{drive_id: ["is required for shared drives"]} = errors_on(changeset)
    end

    test "rejects personal drive with drive_id", %{user: user} do
      assert {:error, changeset} =
               ConnectedDrives.connect(user.id, %{
                 drive_id: "some-id",
                 drive_name: "Bad Personal",
                 drive_type: "personal"
               })

      assert %{drive_id: ["must be nil for personal drives"]} = errors_on(changeset)
    end

    test "rejects invalid drive_type", %{user: user} do
      assert {:error, changeset} =
               ConnectedDrives.connect(user.id, %{
                 drive_id: nil,
                 drive_name: "Bad",
                 drive_type: "invalid"
               })

      assert %{drive_type: [_]} = errors_on(changeset)
    end
  end

  # ---------------------------------------------------------------
  # toggle
  # ---------------------------------------------------------------

  describe "toggle/2" do
    test "toggles enabled state", %{user: user} do
      {:ok, drive} = ConnectedDrives.ensure_personal_drive(user.id)
      assert drive.enabled == true

      {:ok, toggled} = ConnectedDrives.toggle(drive.id, false)
      assert toggled.enabled == false

      {:ok, toggled_back} = ConnectedDrives.toggle(drive.id, true)
      assert toggled_back.enabled == true
    end

    test "returns not_found for non-existent id" do
      assert {:error, :not_found} = ConnectedDrives.toggle(Ecto.UUID.generate(), true)
    end
  end

  # ---------------------------------------------------------------
  # disconnect
  # ---------------------------------------------------------------

  describe "disconnect/1" do
    test "deletes a connected drive", %{user: user} do
      {:ok, drive} = ConnectedDrives.ensure_personal_drive(user.id)
      assert {:ok, %ConnectedDrive{}} = ConnectedDrives.disconnect(drive.id)
      assert [] = ConnectedDrives.list_for_user(user.id)
    end

    test "returns not_found for non-existent id" do
      assert {:error, :not_found} = ConnectedDrives.disconnect(Ecto.UUID.generate())
    end
  end

  # ---------------------------------------------------------------
  # ensure_personal_drive
  # ---------------------------------------------------------------

  describe "ensure_personal_drive/1" do
    test "creates personal drive on first call", %{user: user} do
      assert {:ok, %ConnectedDrive{} = drive} = ConnectedDrives.ensure_personal_drive(user.id)
      assert drive.drive_name == "My Drive"
      assert drive.drive_type == "personal"
      assert drive.drive_id == nil
      assert drive.enabled == true
    end

    test "is idempotent — second call returns existing drive", %{user: user} do
      {:ok, first} = ConnectedDrives.ensure_personal_drive(user.id)
      {:ok, _second} = ConnectedDrives.ensure_personal_drive(user.id)

      # Only one personal drive should exist
      drives = ConnectedDrives.list_for_user(user.id)
      personal = Enum.filter(drives, &(&1.drive_type == "personal"))
      assert length(personal) == 1
      assert hd(personal).id == first.id
    end

    test "different users can both have personal drives", %{user: user, user2: user2} do
      {:ok, d1} = ConnectedDrives.ensure_personal_drive(user.id)
      {:ok, d2} = ConnectedDrives.ensure_personal_drive(user2.id)

      assert d1.id != d2.id
      assert d1.user_id == user.id
      assert d2.user_id == user2.id
    end
  end
end
