defmodule Assistant.Sync.FileManagerTest do
  use Assistant.DataCase, async: true

  alias Assistant.Repo
  alias Assistant.Schemas.SyncedFile
  alias Assistant.Schemas.User
  alias Assistant.Sync.FileManager

  setup do
    user_a = insert_user("file-manager-a")
    user_b = insert_user("file-manager-b")
    %{user_a: user_a, user_b: user_b}
  end

  describe "write_file/3 and read_file/2" do
    test "writes to an existing synced file and reads it back", %{user_a: user_a} do
      insert_synced_file(user_a.id, "test.md")

      content = "Hello, encrypted world!"
      assert {:ok, "test.md"} = FileManager.write_file(user_a.id, "test.md", content)

      assert {:ok, "Hello, encrypted world!"} = FileManager.read_file(user_a.id, "test.md")
    end

    test "writes to nested paths when row exists", %{user_a: user_a} do
      insert_synced_file(user_a.id, "sub/dir/file.txt")

      content = "nested content"

      assert {:ok, "sub/dir/file.txt"} =
               FileManager.write_file(user_a.id, "sub/dir/file.txt", content)

      assert {:ok, "nested content"} = FileManager.read_file(user_a.id, "sub/dir/file.txt")
    end

    test "write_file returns :enoent when synced row does not exist", %{user_a: user_a} do
      assert {:error, :enoent} = FileManager.write_file(user_a.id, "nonexistent.md", "content")
    end

    test "read_file returns :enoent for nonexistent file", %{user_a: user_a} do
      assert {:error, :enoent} = FileManager.read_file(user_a.id, "nonexistent.md")
    end

    test "overwrites existing content", %{user_a: user_a} do
      insert_synced_file(user_a.id, "overwrite.md")

      assert {:ok, "overwrite.md"} = FileManager.write_file(user_a.id, "overwrite.md", "v1")
      assert {:ok, "overwrite.md"} = FileManager.write_file(user_a.id, "overwrite.md", "v2")
      assert {:ok, "v2"} = FileManager.read_file(user_a.id, "overwrite.md")
    end
  end

  describe "path traversal prevention" do
    test "rejects absolute paths", %{user_a: user_a} do
      assert {:error, :path_not_allowed} =
               FileManager.write_file(user_a.id, "/etc/passwd", "hack")
    end

    test "rejects ../ traversal", %{user_a: user_a} do
      assert {:error, :path_not_allowed} =
               FileManager.write_file(user_a.id, "../escape.txt", "hack")
    end

    test "rejects nested ../ traversal", %{user_a: user_a} do
      assert {:error, :path_not_allowed} =
               FileManager.write_file(user_a.id, "sub/../../escape.txt", "hack")
    end

    test "rejects ../ in read_file", %{user_a: user_a} do
      assert {:error, :path_not_allowed} =
               FileManager.read_file(user_a.id, "../other_user/secret.md")
    end

    test "rejects ../ in delete_file", %{user_a: user_a} do
      assert {:error, :path_not_allowed} =
               FileManager.delete_file(user_a.id, "../escape.txt")
    end

    test "rejects absolute path in build_path", %{user_a: user_a} do
      assert {:error, :path_not_allowed} = FileManager.build_path(user_a.id, "/tmp/evil")
    end

    test "rejects ../ in build_path", %{user_a: user_a} do
      assert {:error, :path_not_allowed} = FileManager.build_path(user_a.id, "../escape")
    end
  end

  describe "per-user isolation" do
    test "user A cannot access user B's files", %{user_a: user_a, user_b: user_b} do
      insert_synced_file(user_a.id, "private.md")
      assert {:ok, "private.md"} = FileManager.write_file(user_a.id, "private.md", "A's secret")

      assert {:error, :enoent} = FileManager.read_file(user_b.id, "private.md")
    end

    test "users can have same local_path independently", %{user_a: user_a, user_b: user_b} do
      insert_synced_file(user_a.id, "shared_name.md")
      insert_synced_file(user_b.id, "shared_name.md")

      assert {:ok, "shared_name.md"} =
               FileManager.write_file(user_a.id, "shared_name.md", "A content")

      assert {:ok, "shared_name.md"} =
               FileManager.write_file(user_b.id, "shared_name.md", "B content")

      assert {:ok, "A content"} = FileManager.read_file(user_a.id, "shared_name.md")
      assert {:ok, "B content"} = FileManager.read_file(user_b.id, "shared_name.md")
    end
  end

  describe "delete_file/2" do
    test "clears content for existing file", %{user_a: user_a} do
      record = insert_synced_file(user_a.id, "to_delete.md", "bye")
      assert :ok = FileManager.delete_file(user_a.id, "to_delete.md")

      refreshed = Repo.get!(SyncedFile, record.id)
      assert is_nil(refreshed.content)
      assert {:error, :enoent} = FileManager.read_file(user_a.id, "to_delete.md")
    end

    test "returns :ok for nonexistent file", %{user_a: user_a} do
      assert :ok = FileManager.delete_file(user_a.id, "never_existed.md")
    end
  end

  describe "rename_file/3" do
    test "updates local_path for existing file", %{user_a: user_a} do
      insert_synced_file(user_a.id, "old_name.md", "content")

      assert :ok = FileManager.rename_file(user_a.id, "old_name.md", "new_name.md")

      assert {:error, :enoent} = FileManager.read_file(user_a.id, "old_name.md")
      assert {:ok, "content"} = FileManager.read_file(user_a.id, "new_name.md")
    end

    test "returns :enoent when source path does not exist", %{user_a: user_a} do
      assert {:error, :enoent} = FileManager.rename_file(user_a.id, "missing.md", "renamed.md")
    end

    test "rejects traversal in source path", %{user_a: user_a} do
      assert {:error, :path_not_allowed} =
               FileManager.rename_file(user_a.id, "../escape.md", "safe.md")
    end

    test "rejects traversal in destination path", %{user_a: user_a} do
      insert_synced_file(user_a.id, "source.md", "data")

      assert {:error, :path_not_allowed} =
               FileManager.rename_file(user_a.id, "source.md", "../escape.md")
    end
  end

  describe "list_files/2" do
    test "returns only paths with non-nil content", %{user_a: user_a} do
      insert_synced_file(user_a.id, "a.md", "data")
      insert_synced_file(user_a.id, "sub/b.csv", "data")
      insert_synced_file(user_a.id, "empty.txt", nil)

      assert {:ok, files} = FileManager.list_files(user_a.id)
      assert Enum.sort(files) == ["a.md", "sub/b.csv"]
    end

    test "applies prefix filtering", %{user_a: user_a} do
      insert_synced_file(user_a.id, "docs/a.md", "a")
      insert_synced_file(user_a.id, "docs/b.md", "b")
      insert_synced_file(user_a.id, "other/c.md", "c")

      assert {:ok, files} = FileManager.list_files(user_a.id, "docs/")
      assert Enum.sort(files) == ["docs/a.md", "docs/b.md"]
    end
  end

  describe "checksum/1" do
    test "returns consistent 16-char hex string" do
      checksum = FileManager.checksum("hello world")
      assert is_binary(checksum)
      assert String.length(checksum) == 16
      assert checksum =~ ~r/^[0-9a-f]{16}$/
    end

    test "same content produces same checksum" do
      assert FileManager.checksum("test") == FileManager.checksum("test")
    end

    test "different content produces different checksum" do
      refute FileManager.checksum("aaa") == FileManager.checksum("bbb")
    end

    test "handles empty string" do
      checksum = FileManager.checksum("")
      assert String.length(checksum) == 16
    end
  end

  describe "ensure_user_dir/1" do
    test "returns :ok" do
      assert :ok = FileManager.ensure_user_dir(Ecto.UUID.generate())
    end

    test "is idempotent" do
      user_id = Ecto.UUID.generate()
      assert :ok = FileManager.ensure_user_dir(user_id)
      assert :ok = FileManager.ensure_user_dir(user_id)
    end
  end

  describe "build_path/2" do
    test "returns relative path for valid relative path" do
      user_id = Ecto.UUID.generate()
      assert {:ok, "test.md"} = FileManager.build_path(user_id, "test.md")
    end

    test "rejects unsafe paths" do
      user_id = Ecto.UUID.generate()
      assert {:error, :path_not_allowed} = FileManager.build_path(user_id, "/etc/passwd")
      assert {:error, :path_not_allowed} = FileManager.build_path(user_id, "../escape")
    end
  end

  defp insert_user(prefix) do
    %User{}
    |> User.changeset(%{
      external_id: "#{prefix}-#{System.unique_integer([:positive])}",
      channel: "test"
    })
    |> Repo.insert!()
  end

  defp insert_synced_file(user_id, local_path, content \\ nil) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    %SyncedFile{}
    |> SyncedFile.changeset(%{
      user_id: user_id,
      drive_file_id: "drive-#{System.unique_integer([:positive])}",
      drive_file_name: Path.basename(local_path),
      drive_mime_type: "text/plain",
      local_path: local_path,
      local_format: "txt",
      local_modified_at: now,
      remote_modified_at: now,
      sync_status: "synced",
      last_synced_at: now,
      content: content
    })
    |> Repo.insert!()
  end
end
