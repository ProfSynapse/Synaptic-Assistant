# test/assistant/schemas/connected_drive_test.exs
#
# Schema-level changeset validation tests for ConnectedDrive.
# Tests field validation rules without requiring database operations.
#
# Related files:
#   - lib/assistant/schemas/connected_drive.ex (module under test)

defmodule Assistant.Schemas.ConnectedDriveTest do
  use ExUnit.Case, async: true

  alias Assistant.Schemas.ConnectedDrive

  # ---------------------------------------------------------------
  # changeset validation
  # ---------------------------------------------------------------

  describe "changeset/2" do
    test "valid shared drive changeset" do
      changeset =
        ConnectedDrive.changeset(%ConnectedDrive{}, %{
          user_id: Ecto.UUID.generate(),
          drive_id: "shared-abc",
          drive_name: "Team Drive",
          drive_type: "shared"
        })

      assert changeset.valid?
    end

    test "valid personal drive changeset (nil drive_id)" do
      changeset =
        ConnectedDrive.changeset(%ConnectedDrive{}, %{
          user_id: Ecto.UUID.generate(),
          drive_id: nil,
          drive_name: "My Drive",
          drive_type: "personal"
        })

      assert changeset.valid?
    end

    test "rejects missing user_id" do
      changeset =
        ConnectedDrive.changeset(%ConnectedDrive{}, %{
          drive_name: "Test",
          drive_type: "personal"
        })

      refute changeset.valid?
      assert Keyword.has_key?(changeset.errors, :user_id)
    end

    test "rejects missing drive_name" do
      changeset =
        ConnectedDrive.changeset(%ConnectedDrive{}, %{
          user_id: Ecto.UUID.generate(),
          drive_type: "personal"
        })

      refute changeset.valid?
      assert Keyword.has_key?(changeset.errors, :drive_name)
    end

    test "rejects missing drive_type" do
      changeset =
        ConnectedDrive.changeset(%ConnectedDrive{}, %{
          user_id: Ecto.UUID.generate(),
          drive_name: "Test"
        })

      refute changeset.valid?
      assert Keyword.has_key?(changeset.errors, :drive_type)
    end

    test "rejects invalid drive_type" do
      changeset =
        ConnectedDrive.changeset(%ConnectedDrive{}, %{
          user_id: Ecto.UUID.generate(),
          drive_name: "Test",
          drive_type: "invalid"
        })

      refute changeset.valid?
      assert Keyword.has_key?(changeset.errors, :drive_type)
    end

    test "rejects personal drive with non-nil drive_id" do
      changeset =
        ConnectedDrive.changeset(%ConnectedDrive{}, %{
          user_id: Ecto.UUID.generate(),
          drive_id: "some-id",
          drive_name: "My Drive",
          drive_type: "personal"
        })

      refute changeset.valid?
      assert {"must be nil for personal drives", _} = changeset.errors[:drive_id]
    end

    test "rejects shared drive without drive_id" do
      changeset =
        ConnectedDrive.changeset(%ConnectedDrive{}, %{
          user_id: Ecto.UUID.generate(),
          drive_id: nil,
          drive_name: "Shared",
          drive_type: "shared"
        })

      refute changeset.valid?
      assert {"is required for shared drives", _} = changeset.errors[:drive_id]
    end

    test "enabled defaults to true" do
      changeset =
        ConnectedDrive.changeset(%ConnectedDrive{}, %{
          user_id: Ecto.UUID.generate(),
          drive_name: "My Drive",
          drive_type: "personal"
        })

      assert Ecto.Changeset.get_field(changeset, :enabled) == true
    end

    test "enabled can be set to false" do
      changeset =
        ConnectedDrive.changeset(%ConnectedDrive{}, %{
          user_id: Ecto.UUID.generate(),
          drive_name: "My Drive",
          drive_type: "personal",
          enabled: false
        })

      assert changeset.valid?
      assert Ecto.Changeset.get_field(changeset, :enabled) == false
    end
  end
end
