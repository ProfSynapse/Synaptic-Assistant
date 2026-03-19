defmodule Assistant.Schemas.DocumentFolderTest do
  use Assistant.DataCase, async: true

  import Assistant.MemoryFixtures
  alias Assistant.Schemas.DocumentFolder

  describe "changeset/2" do
    test "valid changeset with required fields" do
      user = user_fixture()
      attrs = %{drive_folder_id: "folder-123", name: "Project Alpha", user_id: user.id}
      changeset = DocumentFolder.changeset(%DocumentFolder{}, attrs)
      assert changeset.valid?
    end

    test "invalid changeset without drive_folder_id" do
      user = user_fixture()
      changeset = DocumentFolder.changeset(%DocumentFolder{}, %{name: "Test", user_id: user.id})
      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).drive_folder_id
    end

    test "invalid changeset without name" do
      user = user_fixture()

      changeset =
        DocumentFolder.changeset(%DocumentFolder{}, %{drive_folder_id: "f-1", user_id: user.id})

      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).name
    end

    test "invalid changeset without user_id" do
      changeset =
        DocumentFolder.changeset(%DocumentFolder{}, %{drive_folder_id: "f-1", name: "Test"})

      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).user_id
    end

    test "accepts optional fields" do
      user = user_fixture()

      attrs = %{
        drive_folder_id: "folder-456",
        name: "Shared Folder",
        user_id: user.id,
        drive_id: "shared-drive-1",
        activation_boost: 1.2,
        child_count: 5
      }

      changeset = DocumentFolder.changeset(%DocumentFolder{}, attrs)
      assert changeset.valid?
    end

    test "default activation_boost is 1.0" do
      user = user_fixture()

      {:ok, folder} =
        %DocumentFolder{}
        |> DocumentFolder.changeset(%{drive_folder_id: "f-1", name: "Test", user_id: user.id})
        |> Repo.insert()

      assert folder.activation_boost == 1.0
    end

    test "default child_count is 0" do
      user = user_fixture()

      {:ok, folder} =
        %DocumentFolder{}
        |> DocumentFolder.changeset(%{drive_folder_id: "f-2", name: "Test", user_id: user.id})
        |> Repo.insert()

      assert folder.child_count == 0
    end
  end

  describe "upsert/1" do
    test "creates a new folder" do
      user = user_fixture()

      assert {:ok, folder} =
               DocumentFolder.upsert(%{
                 drive_folder_id: "folder-new",
                 name: "New Folder",
                 user_id: user.id
               })

      assert folder.drive_folder_id == "folder-new"
      assert folder.name == "New Folder"
    end

    test "updates name on conflict" do
      user = user_fixture()

      {:ok, _} =
        DocumentFolder.upsert(%{
          drive_folder_id: "folder-upsert",
          name: "Original Name",
          user_id: user.id
        })

      {:ok, updated} =
        DocumentFolder.upsert(%{
          drive_folder_id: "folder-upsert",
          name: "Updated Name",
          user_id: user.id
        })

      assert updated.name == "Updated Name"
      assert updated.drive_folder_id == "folder-upsert"
    end

    test "unique constraint on user_id + drive_folder_id" do
      user = user_fixture()

      {:ok, _} =
        DocumentFolder.upsert(%{
          drive_folder_id: "folder-unique",
          name: "First",
          user_id: user.id
        })

      # Upsert should not raise — it updates instead
      {:ok, second} =
        DocumentFolder.upsert(%{
          drive_folder_id: "folder-unique",
          name: "Second",
          user_id: user.id
        })

      assert second.name == "Second"
    end

    test "different users can have same drive_folder_id" do
      user1 = user_fixture()
      user2 = user_fixture()

      {:ok, f1} =
        DocumentFolder.upsert(%{drive_folder_id: "shared", name: "Folder", user_id: user1.id})

      {:ok, f2} =
        DocumentFolder.upsert(%{drive_folder_id: "shared", name: "Folder", user_id: user2.id})

      assert f1.id != f2.id
    end
  end
end
