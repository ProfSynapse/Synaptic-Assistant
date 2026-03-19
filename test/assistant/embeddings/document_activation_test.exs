defmodule Assistant.Embeddings.DocumentActivationTest do
  use Assistant.DataCase, async: true

  import Assistant.MemoryFixtures
  alias Assistant.Embeddings.DocumentActivation
  alias Assistant.Schemas.DocumentFolder

  defp create_folder!(user, drive_folder_id, name) do
    {:ok, folder} =
      DocumentFolder.upsert(%{
        drive_folder_id: drive_folder_id,
        name: name,
        user_id: user.id
      })

    folder
  end

  describe "spread/2 with empty or invalid input" do
    test "handles empty list" do
      assert :ok = DocumentActivation.spread(Ecto.UUID.generate(), [])
    end

    test "handles non-list input" do
      assert :ok = DocumentActivation.spread(Ecto.UUID.generate(), "not a list")
    end

    test "handles nil input" do
      assert :ok = DocumentActivation.spread(Ecto.UUID.generate(), nil)
    end
  end

  describe "spread/2 with folder metadata" do
    test "boosts folder activation_boost when chunks from that folder are retrieved" do
      user = user_fixture()
      folder = create_folder!(user, "folder-a", "Project Alpha")

      # Simulate retrieved chunks with folder metadata
      chunks = [
        %{metadata: %{"parent_folder_id" => "folder-a"}, document_id: "doc-1"},
        %{metadata: %{"parent_folder_id" => "folder-a"}, document_id: "doc-2"}
      ]

      DocumentActivation.spread(user.id, chunks)

      reloaded = Repo.get!(DocumentFolder, folder.id)
      # activation_boost should be boosted by 0.03 * 2 chunks = 0.06
      assert_in_delta reloaded.activation_boost, 1.06, 0.01
    end

    test "caps activation_boost at 1.3" do
      user = user_fixture()
      folder = create_folder!(user, "folder-cap", "Hot Folder")

      # Set activation close to max
      from(df in DocumentFolder, where: df.id == ^folder.id)
      |> Repo.update_all(set: [activation_boost: 1.29])

      # Spread more activation — 10 chunks * 0.03 = 0.30, would push to 1.59
      chunks =
        for i <- 1..10,
            do: %{metadata: %{"parent_folder_id" => "folder-cap"}, document_id: "doc-#{i}"}

      DocumentActivation.spread(user.id, chunks)

      reloaded = Repo.get!(DocumentFolder, folder.id)
      assert reloaded.activation_boost <= 1.3
    end

    test "skips chunks without parent_folder_id" do
      user = user_fixture()

      chunks = [
        %{metadata: %{}, document_id: "doc-1"},
        %{metadata: %{"other_key" => "value"}, document_id: "doc-2"}
      ]

      # Should not raise — nil folder_id key is grouped and skipped
      assert :ok = DocumentActivation.spread(user.id, chunks)
    end

    test "handles nil parent_folder_id" do
      user = user_fixture()

      chunks = [
        %{metadata: %{"parent_folder_id" => nil}, document_id: "doc-1"}
      ]

      # nil folder_id is skipped by the {nil, _chunks} -> :skip clause
      assert :ok = DocumentActivation.spread(user.id, chunks)
    end

    test "handles chunks with no metadata key" do
      user = user_fixture()
      chunks = [%{document_id: "doc-1"}]

      # The _ catch-all in the group_by returns nil, which gets skipped
      assert :ok = DocumentActivation.spread(user.id, chunks)
    end

    test "groups chunks by folder and boosts each independently" do
      user = user_fixture()
      folder_a = create_folder!(user, "folder-aa", "Folder A")
      folder_b = create_folder!(user, "folder-bb", "Folder B")

      chunks = [
        %{metadata: %{"parent_folder_id" => "folder-aa"}, document_id: "doc-1"},
        %{metadata: %{"parent_folder_id" => "folder-bb"}, document_id: "doc-2"},
        %{metadata: %{"parent_folder_id" => "folder-bb"}, document_id: "doc-3"}
      ]

      DocumentActivation.spread(user.id, chunks)

      reloaded_a = Repo.get!(DocumentFolder, folder_a.id)
      reloaded_b = Repo.get!(DocumentFolder, folder_b.id)

      # Folder A: 1 chunk -> boost by 0.03
      assert_in_delta reloaded_a.activation_boost, 1.03, 0.01
      # Folder B: 2 chunks -> boost by 0.06
      assert_in_delta reloaded_b.activation_boost, 1.06, 0.01
    end

    test "boosts correctly from sub-default activation_boost (< 1.0)" do
      user = user_fixture()
      folder = create_folder!(user, "folder-low", "Cold Folder")

      # Set activation_boost below default to simulate over-cooled folder
      import Ecto.Query

      from(df in DocumentFolder, where: df.id == ^folder.id)
      |> Repo.update_all(set: [activation_boost: 0.8])

      chunks = [
        %{metadata: %{"parent_folder_id" => "folder-low"}, document_id: "doc-1"}
      ]

      DocumentActivation.spread(user.id, chunks)

      reloaded = Repo.get!(DocumentFolder, folder.id)
      # SQL: LEAST(1.3, COALESCE(0.8, 1.0) + 0.03) = LEAST(1.3, 0.83) = 0.83
      assert_in_delta reloaded.activation_boost, 0.83, 0.01
    end

    test "boosts from nil activation_boost defaults to COALESCE 1.0" do
      user = user_fixture()
      folder = create_folder!(user, "folder-nil", "Nil Boost Folder")

      # Force activation_boost to NULL via raw SQL
      Repo.query!("UPDATE document_folders SET activation_boost = NULL WHERE id = $1", [
        Ecto.UUID.dump!(folder.id)
      ])

      chunks = [
        %{metadata: %{"parent_folder_id" => "folder-nil"}, document_id: "doc-1"},
        %{metadata: %{"parent_folder_id" => "folder-nil"}, document_id: "doc-2"}
      ]

      DocumentActivation.spread(user.id, chunks)

      reloaded = Repo.get!(DocumentFolder, folder.id)
      # SQL: LEAST(1.3, COALESCE(NULL, 1.0) + 0.03 * 2) = LEAST(1.3, 1.06) = 1.06
      assert_in_delta reloaded.activation_boost, 1.06, 0.01
    end

    test "does not create folders for unknown drive_folder_ids" do
      user = user_fixture()
      # Spread activation referencing a folder_id that doesn't exist in DB
      chunks = [
        %{metadata: %{"parent_folder_id" => "nonexistent-folder"}, document_id: "doc-1"}
      ]

      # Should not raise — update_all simply matches zero rows
      assert :ok = DocumentActivation.spread(user.id, chunks)

      # Verify no folder was created
      assert Repo.all(DocumentFolder) == []
    end

    test "accumulates boosts across multiple spread calls" do
      user = user_fixture()
      folder = create_folder!(user, "folder-acc", "Accumulator")

      chunks = [%{metadata: %{"parent_folder_id" => "folder-acc"}, document_id: "doc-1"}]

      # First spread: 1.0 + 0.03 = 1.03
      DocumentActivation.spread(user.id, chunks)
      reloaded = Repo.get!(DocumentFolder, folder.id)
      assert_in_delta reloaded.activation_boost, 1.03, 0.01

      # Second spread: 1.03 + 0.03 = 1.06
      DocumentActivation.spread(user.id, chunks)
      reloaded = Repo.get!(DocumentFolder, folder.id)
      assert_in_delta reloaded.activation_boost, 1.06, 0.01
    end

    test "does not boost folders belonging to a different user" do
      user = user_fixture()
      other_user = user_fixture()
      _folder = create_folder!(user, "shared-id", "User Folder")
      other_folder = create_folder!(other_user, "shared-id", "Other Folder")

      chunks = [
        %{metadata: %{"parent_folder_id" => "shared-id"}, document_id: "doc-1"}
      ]

      # Spread as user — should not affect other_user's folder
      DocumentActivation.spread(user.id, chunks)

      reloaded_other = Repo.get!(DocumentFolder, other_folder.id)
      assert_in_delta reloaded_other.activation_boost, 1.0, 0.001
    end
  end
end
