# test/assistant/sync/state_store_test.exs
#
# Tests for Assistant.Sync.StateStore — Ecto context for sync engine state.
# Covers CRUD for cursors, synced files, history entries, and sync scopes,
# including partial unique index upserts.
#
# Related files:
#   - lib/assistant/sync/state_store.ex (module under test)
#   - lib/assistant/schemas/sync_cursor.ex
#   - lib/assistant/schemas/synced_file.ex
#   - lib/assistant/schemas/sync_history_entry.ex
#   - lib/assistant/schemas/sync_scope.ex

defmodule Assistant.Sync.StateStoreTest do
  use Assistant.DataCase, async: true

  alias Assistant.Sync.StateStore

  # ---------------------------------------------------------------
  # Setup — create test users
  # ---------------------------------------------------------------

  setup do
    user = insert_test_user("state-store")
    user_b = insert_test_user("state-store-b")
    %{user: user, user_b: user_b}
  end

  defp insert_test_user(prefix) do
    %Assistant.Schemas.User{}
    |> Assistant.Schemas.User.changeset(%{
      external_id: "#{prefix}-#{System.unique_integer([:positive])}",
      channel: "test"
    })
    |> Repo.insert!()
  end

  # ---------------------------------------------------------------
  # Cursors
  # ---------------------------------------------------------------

  describe "cursors" do
    test "get_cursor returns nil when no cursor exists", %{user: user} do
      assert nil == StateStore.get_cursor(user.id, nil)
    end

    test "upsert_cursor creates and returns cursor", %{user: user} do
      assert {:ok, cursor} =
               StateStore.upsert_cursor(%{
                 user_id: user.id,
                 drive_id: nil,
                 start_page_token: "token-123",
                 last_poll_at: DateTime.utc_now()
               })

      assert cursor.start_page_token == "token-123"
      assert cursor.user_id == user.id
    end

    test "upsert_cursor updates on conflict (personal drive)", %{user: user} do
      {:ok, _} =
        StateStore.upsert_cursor(%{
          user_id: user.id,
          drive_id: nil,
          start_page_token: "token-v1"
        })

      {:ok, updated} =
        StateStore.upsert_cursor(%{
          user_id: user.id,
          drive_id: nil,
          start_page_token: "token-v2"
        })

      assert updated.start_page_token == "token-v2"

      # Only one cursor should exist
      cursors = StateStore.list_cursors(user.id)
      assert length(cursors) == 1
    end

    test "upsert_cursor updates on conflict (shared drive)", %{user: user} do
      drive_id = "shared-drive-001"

      {:ok, _} =
        StateStore.upsert_cursor(%{
          user_id: user.id,
          drive_id: drive_id,
          start_page_token: "v1"
        })

      {:ok, updated} =
        StateStore.upsert_cursor(%{
          user_id: user.id,
          drive_id: drive_id,
          start_page_token: "v2"
        })

      assert updated.start_page_token == "v2"
    end

    test "personal and shared drive cursors are independent", %{user: user} do
      {:ok, _} =
        StateStore.upsert_cursor(%{
          user_id: user.id,
          drive_id: nil,
          start_page_token: "personal-token"
        })

      {:ok, _} =
        StateStore.upsert_cursor(%{
          user_id: user.id,
          drive_id: "shared-001",
          start_page_token: "shared-token"
        })

      cursors = StateStore.list_cursors(user.id)
      assert length(cursors) == 2

      personal = StateStore.get_cursor(user.id, nil)
      assert personal.start_page_token == "personal-token"

      shared = StateStore.get_cursor(user.id, "shared-001")
      assert shared.start_page_token == "shared-token"
    end

    test "list_cursors returns all cursors for user", %{user: user} do
      {:ok, _} =
        StateStore.upsert_cursor(%{user_id: user.id, drive_id: nil, start_page_token: "t1"})

      {:ok, _} =
        StateStore.upsert_cursor(%{user_id: user.id, drive_id: "d1", start_page_token: "t2"})

      cursors = StateStore.list_cursors(user.id)
      assert length(cursors) == 2
    end

    test "delete_cursor removes cursor", %{user: user} do
      {:ok, _} =
        StateStore.upsert_cursor(%{user_id: user.id, drive_id: nil, start_page_token: "t"})

      assert {1, _} = StateStore.delete_cursor(user.id, nil)
      assert nil == StateStore.get_cursor(user.id, nil)
    end

    test "delete_cursor with non-nil drive_id", %{user: user} do
      {:ok, _} =
        StateStore.upsert_cursor(%{user_id: user.id, drive_id: "d1", start_page_token: "t"})

      assert {1, _} = StateStore.delete_cursor(user.id, "d1")
      assert nil == StateStore.get_cursor(user.id, "d1")
    end
  end

  # ---------------------------------------------------------------
  # Synced Files
  # ---------------------------------------------------------------

  describe "synced files" do
    test "create and get synced file", %{user: user} do
      assert {:ok, file} =
               StateStore.create_synced_file(%{
                 user_id: user.id,
                 drive_file_id: "drive-file-001",
                 drive_file_name: "test.md",
                 drive_mime_type: "text/markdown",
                 local_path: "test.md",
                 local_format: "md",
                 sync_status: "synced"
               })

      assert file.drive_file_id == "drive-file-001"

      fetched = StateStore.get_synced_file(user.id, "drive-file-001")
      assert fetched.id == file.id
    end

    test "get_synced_file returns nil for unknown file", %{user: user} do
      assert nil == StateStore.get_synced_file(user.id, "nonexistent")
    end

    test "get_synced_file_by_id returns file by primary key", %{user: user} do
      {:ok, file} =
        StateStore.create_synced_file(%{
          user_id: user.id,
          drive_file_id: "df-by-id",
          drive_file_name: "byid.md",
          drive_mime_type: "text/plain",
          local_path: "byid.md",
          local_format: "md",
          sync_status: "synced"
        })

      assert StateStore.get_synced_file_by_id(file.id).drive_file_id == "df-by-id"
    end

    test "update_synced_file changes sync state", %{user: user} do
      {:ok, file} =
        StateStore.create_synced_file(%{
          user_id: user.id,
          drive_file_id: "df-update",
          drive_file_name: "update.md",
          drive_mime_type: "text/plain",
          local_path: "update.md",
          local_format: "md",
          sync_status: "synced"
        })

      assert {:ok, updated} =
               StateStore.update_synced_file(file, %{
                 sync_status: "conflict",
                 sync_error: "Both sides changed"
               })

      assert updated.sync_status == "conflict"
      assert updated.sync_error == "Both sides changed"
    end

    test "list_synced_files filters by status", %{user: user} do
      {:ok, _} =
        StateStore.create_synced_file(%{
          user_id: user.id,
          drive_file_id: "s1",
          drive_file_name: "s1.md",
          drive_mime_type: "text/plain",
          local_path: "s1.md",
          local_format: "md",
          sync_status: "synced"
        })

      {:ok, _} =
        StateStore.create_synced_file(%{
          user_id: user.id,
          drive_file_id: "e1",
          drive_file_name: "e1.md",
          drive_mime_type: "text/plain",
          local_path: "e1.md",
          local_format: "md",
          sync_status: "error"
        })

      synced = StateStore.list_synced_files(user.id, status: "synced")
      assert length(synced) == 1
      assert hd(synced).drive_file_id == "s1"

      errors = StateStore.list_synced_files(user.id, status: "error")
      assert length(errors) == 1

      all = StateStore.list_synced_files(user.id)
      assert length(all) == 2
    end

    test "list_synced_files filters by drive_id", %{user: user} do
      {:ok, _} =
        StateStore.create_synced_file(%{
          user_id: user.id,
          drive_file_id: "personal-f",
          drive_file_name: "p.md",
          drive_mime_type: "text/plain",
          local_path: "p.md",
          local_format: "md",
          sync_status: "synced",
          drive_id: nil
        })

      {:ok, _} =
        StateStore.create_synced_file(%{
          user_id: user.id,
          drive_file_id: "shared-f",
          drive_file_name: "s.md",
          drive_mime_type: "text/plain",
          local_path: "s.md",
          local_format: "md",
          sync_status: "synced",
          drive_id: "shared-001"
        })

      personal = StateStore.list_synced_files(user.id, drive_id: :personal)
      assert length(personal) == 1
      assert hd(personal).drive_file_id == "personal-f"

      shared = StateStore.list_synced_files(user.id, drive_id: "shared-001")
      assert length(shared) == 1
      assert hd(shared).drive_file_id == "shared-f"
    end

    test "count_synced_files_by_status returns grouped counts", %{user: user} do
      for {id, status} <- [
            {"c1", "synced"},
            {"c2", "synced"},
            {"c3", "conflict"},
            {"c4", "error"}
          ] do
        StateStore.create_synced_file(%{
          user_id: user.id,
          drive_file_id: id,
          drive_file_name: "#{id}.md",
          drive_mime_type: "text/plain",
          local_path: "#{id}.md",
          local_format: "md",
          sync_status: status
        })
      end

      counts = StateStore.count_synced_files_by_status(user.id)
      assert counts["synced"] == 2
      assert counts["conflict"] == 1
      assert counts["error"] == 1
    end

    test "delete_synced_file removes file record", %{user: user} do
      {:ok, file} =
        StateStore.create_synced_file(%{
          user_id: user.id,
          drive_file_id: "to-delete",
          drive_file_name: "del.md",
          drive_mime_type: "text/plain",
          local_path: "del.md",
          local_format: "md",
          sync_status: "synced"
        })

      assert {:ok, _} = StateStore.delete_synced_file(file)
      assert nil == StateStore.get_synced_file(user.id, "to-delete")
    end
  end

  # ---------------------------------------------------------------
  # History
  # ---------------------------------------------------------------

  describe "history" do
    setup %{user: user} do
      {:ok, file} =
        StateStore.create_synced_file(%{
          user_id: user.id,
          drive_file_id: "hist-file",
          drive_file_name: "hist.md",
          drive_mime_type: "text/plain",
          local_path: "hist.md",
          local_format: "md",
          sync_status: "synced"
        })

      %{synced_file: file}
    end

    test "create and list history entries", %{synced_file: file} do
      {:ok, entry} =
        StateStore.create_history_entry(%{
          synced_file_id: file.id,
          operation: "download",
          details: %{"message" => "Downloaded hist.md"}
        })

      assert entry.operation == "download"

      entries = StateStore.list_history(file.id)
      assert length(entries) == 1
      assert hd(entries).id == entry.id
    end

    test "list_history respects limit", %{synced_file: file} do
      for op <- ~w(download upload download) do
        StateStore.create_history_entry(%{
          synced_file_id: file.id,
          operation: op,
          details: %{"info" => "test"}
        })
      end

      limited = StateStore.list_history(file.id, limit: 2)
      assert length(limited) == 2
    end

    test "list_user_history returns entries across files", %{user: user, synced_file: file} do
      {:ok, file2} =
        StateStore.create_synced_file(%{
          user_id: user.id,
          drive_file_id: "hist-file-2",
          drive_file_name: "hist2.md",
          drive_mime_type: "text/plain",
          local_path: "hist2.md",
          local_format: "md",
          sync_status: "synced"
        })

      StateStore.create_history_entry(%{
        synced_file_id: file.id,
        operation: "download",
        details: %{"info" => "f1"}
      })

      StateStore.create_history_entry(%{
        synced_file_id: file2.id,
        operation: "upload",
        details: %{"info" => "f2"}
      })

      history = StateStore.list_user_history(user.id)
      assert length(history) == 2
      # Should include file_name from join
      names = Enum.map(history, & &1.file_name)
      assert "hist.md" in names
      assert "hist2.md" in names
    end

    test "history entries have all valid operations", %{synced_file: file} do
      valid_ops =
        ~w(download upload conflict_detect conflict_resolve delete_local trash untrash error)

      for op <- valid_ops do
        assert {:ok, _} =
                 StateStore.create_history_entry(%{
                   synced_file_id: file.id,
                   operation: op,
                   details: %{"info" => "test #{op}"}
                 })
      end

      entries = StateStore.list_history(file.id)
      assert length(entries) == 8
    end
  end

  # ---------------------------------------------------------------
  # Scopes
  # ---------------------------------------------------------------

  describe "scopes" do
    test "get_scope returns nil when no scope exists", %{user: user} do
      assert nil == StateStore.get_scope(user.id, nil, nil)
    end

    test "upsert_scope creates scope", %{user: user} do
      assert {:ok, scope} =
               StateStore.upsert_scope(%{
                 user_id: user.id,
                 drive_id: nil,
                 folder_id: nil,
                 folder_name: "My Drive (all)",
                 access_level: "read_only"
               })

      assert scope.folder_name == "My Drive (all)"
      assert scope.access_level == "read_only"
    end

    test "upsert_scope updates on conflict (personal drive, entire drive)", %{user: user} do
      {:ok, _} =
        StateStore.upsert_scope(%{
          user_id: user.id,
          drive_id: nil,
          folder_id: nil,
          folder_name: "My Drive v1"
        })

      {:ok, updated} =
        StateStore.upsert_scope(%{
          user_id: user.id,
          drive_id: nil,
          folder_id: nil,
          folder_name: "My Drive v2",
          access_level: "read_write"
        })

      assert updated.folder_name == "My Drive v2"
      assert updated.access_level == "read_write"

      scopes = StateStore.list_scopes(user.id)
      assert length(scopes) == 1
    end

    test "upsert_scope with shared drive and specific folder", %{user: user} do
      {:ok, _} =
        StateStore.upsert_scope(%{
          user_id: user.id,
          drive_id: "shared-001",
          folder_id: "folder-abc",
          folder_name: "Reports"
        })

      {:ok, updated} =
        StateStore.upsert_scope(%{
          user_id: user.id,
          drive_id: "shared-001",
          folder_id: "folder-abc",
          folder_name: "Reports (updated)"
        })

      assert updated.folder_name == "Reports (updated)"
    end

    test "4-way partial index independence", %{user: user} do
      # All 4 combos of NULL/NOT NULL for drive_id x folder_id
      scopes = [
        %{user_id: user.id, drive_id: nil, folder_id: nil, folder_name: "Personal All"},
        %{user_id: user.id, drive_id: nil, folder_id: "f1", folder_name: "Personal Folder"},
        %{user_id: user.id, drive_id: "d1", folder_id: nil, folder_name: "Shared All"},
        %{user_id: user.id, drive_id: "d1", folder_id: "f1", folder_name: "Shared Folder"}
      ]

      for s <- scopes, do: {:ok, _} = StateStore.upsert_scope(s)

      all_scopes = StateStore.list_scopes(user.id)
      assert length(all_scopes) == 4
    end

    test "list_scopes filters by drive_id", %{user: user} do
      StateStore.upsert_scope(%{
        user_id: user.id,
        drive_id: nil,
        folder_id: nil,
        folder_name: "P"
      })

      StateStore.upsert_scope(%{
        user_id: user.id,
        drive_id: "d1",
        folder_id: nil,
        folder_name: "S"
      })

      personal = StateStore.list_scopes(user.id, drive_id: :personal)
      assert length(personal) == 1
      assert hd(personal).folder_name == "P"

      shared = StateStore.list_scopes(user.id, drive_id: "d1")
      assert length(shared) == 1
      assert hd(shared).folder_name == "S"
    end

    test "delete_scope removes scope", %{user: user} do
      {:ok, scope} =
        StateStore.upsert_scope(%{
          user_id: user.id,
          drive_id: nil,
          folder_id: nil,
          folder_name: "To Delete"
        })

      assert {:ok, _} = StateStore.delete_scope(scope)
      assert nil == StateStore.get_scope(user.id, nil, nil)
    end
  end

  # ---------------------------------------------------------------
  # folder_in_scope?
  # ---------------------------------------------------------------

  describe "folder_in_scope?/3" do
    test "returns nil when no scope matches", %{user: user} do
      assert nil == StateStore.folder_in_scope?(user.id, nil, "folder-x")
    end

    test "returns scope when exact folder match", %{user: user} do
      {:ok, _} =
        StateStore.upsert_scope(%{
          user_id: user.id,
          drive_id: nil,
          folder_id: "folder-a",
          folder_name: "Folder A"
        })

      scope = StateStore.folder_in_scope?(user.id, nil, "folder-a")
      assert scope != nil
      assert scope.folder_name == "Folder A"
    end

    test "falls back to entire-drive scope when folder-specific absent", %{user: user} do
      # Create entire-drive scope (folder_id=nil) but NOT a folder-specific one
      {:ok, _} =
        StateStore.upsert_scope(%{
          user_id: user.id,
          drive_id: nil,
          folder_id: nil,
          folder_name: "My Drive (all)"
        })

      # Any folder should match via the entire-drive fallback
      scope = StateStore.folder_in_scope?(user.id, nil, "any-folder")
      assert scope != nil
      assert scope.folder_name == "My Drive (all)"
    end

    test "prefers folder-specific scope over entire-drive scope", %{user: user} do
      {:ok, _} =
        StateStore.upsert_scope(%{
          user_id: user.id,
          drive_id: nil,
          folder_id: nil,
          folder_name: "Entire Drive"
        })

      {:ok, _} =
        StateStore.upsert_scope(%{
          user_id: user.id,
          drive_id: nil,
          folder_id: "specific-folder",
          folder_name: "Specific Folder"
        })

      scope = StateStore.folder_in_scope?(user.id, nil, "specific-folder")
      assert scope.folder_name == "Specific Folder"
    end

    test "works with shared drives", %{user: user} do
      {:ok, _} =
        StateStore.upsert_scope(%{
          user_id: user.id,
          drive_id: "shared-001",
          folder_id: nil,
          folder_name: "Shared Drive All"
        })

      scope = StateStore.folder_in_scope?(user.id, "shared-001", "any-folder")
      assert scope != nil
      assert scope.folder_name == "Shared Drive All"
    end

    test "different users have independent scopes", %{user: user, user_b: user_b} do
      {:ok, _} =
        StateStore.upsert_scope(%{
          user_id: user.id,
          drive_id: nil,
          folder_id: "f1",
          folder_name: "User A folder"
        })

      assert StateStore.folder_in_scope?(user.id, nil, "f1") != nil
      assert StateStore.folder_in_scope?(user_b.id, nil, "f1") == nil
    end
  end
end
