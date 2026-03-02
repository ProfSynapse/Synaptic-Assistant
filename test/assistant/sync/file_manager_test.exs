# test/assistant/sync/file_manager_test.exs
#
# Tests for Assistant.Sync.FileManager — encrypted local file I/O with
# path traversal protection. Security-critical (P0). Uses temp directories
# to avoid polluting the real workspace.
#
# Related files:
#   - lib/assistant/sync/file_manager.ex (module under test)
#   - lib/assistant/vault.ex (Cloak encryption vault)

defmodule Assistant.Sync.FileManagerTest do
  use ExUnit.Case, async: false

  alias Assistant.Sync.FileManager

  @user_a "user-aaa-1111"
  @user_b "user-bbb-2222"

  setup do
    # Create a unique temp directory for each test
    tmp_base = Path.join(System.tmp_dir!(), "fm_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp_base)

    # Override the workspace dir for this test
    original = Application.get_env(:assistant, :sync_workspace_dir)
    Application.put_env(:assistant, :sync_workspace_dir, tmp_base)

    on_exit(fn ->
      # Restore original config
      if original do
        Application.put_env(:assistant, :sync_workspace_dir, original)
      else
        Application.delete_env(:assistant, :sync_workspace_dir)
      end

      # Clean up temp directory
      File.rm_rf!(tmp_base)
    end)

    %{tmp_base: tmp_base}
  end

  # ---------------------------------------------------------------
  # write_file + read_file (encryption round-trip)
  # ---------------------------------------------------------------

  describe "write_file/3 and read_file/2" do
    test "round-trips content through encryption" do
      content = "Hello, encrypted world!"
      assert {:ok, full_path} = FileManager.write_file(@user_a, "test.md", content)
      assert File.exists?(full_path)

      # Raw file on disk should NOT be the original plaintext
      raw = File.read!(full_path)
      refute raw == content

      # Reading back should decrypt to original
      assert {:ok, ^content} = FileManager.read_file(@user_a, "test.md")
    end

    test "writes to nested subdirectories" do
      content = "nested content"
      assert {:ok, _path} = FileManager.write_file(@user_a, "sub/dir/file.txt", content)
      assert {:ok, ^content} = FileManager.read_file(@user_a, "sub/dir/file.txt")
    end

    test "read_file returns :enoent for nonexistent file" do
      assert {:error, :enoent} = FileManager.read_file(@user_a, "nonexistent.md")
    end

    test "overwrites existing file" do
      assert {:ok, _} = FileManager.write_file(@user_a, "overwrite.md", "v1")
      assert {:ok, _} = FileManager.write_file(@user_a, "overwrite.md", "v2")
      assert {:ok, "v2"} = FileManager.read_file(@user_a, "overwrite.md")
    end
  end

  # ---------------------------------------------------------------
  # Path traversal prevention (SECURITY)
  # ---------------------------------------------------------------

  describe "path traversal prevention" do
    test "rejects absolute paths" do
      assert {:error, :path_not_allowed} =
               FileManager.write_file(@user_a, "/etc/passwd", "hack")
    end

    test "rejects ../ traversal" do
      assert {:error, :path_not_allowed} =
               FileManager.write_file(@user_a, "../escape.txt", "hack")
    end

    test "rejects nested ../ traversal" do
      assert {:error, :path_not_allowed} =
               FileManager.write_file(@user_a, "sub/../../escape.txt", "hack")
    end

    test "rejects ../ in read_file" do
      assert {:error, :path_not_allowed} =
               FileManager.read_file(@user_a, "../other_user/secret.md")
    end

    test "rejects ../ in delete_file" do
      assert {:error, :path_not_allowed} =
               FileManager.delete_file(@user_a, "../escape.txt")
    end

    test "rejects absolute path in build_path" do
      assert {:error, :path_not_allowed} = FileManager.build_path(@user_a, "/tmp/evil")
    end

    test "rejects ../ in build_path" do
      assert {:error, :path_not_allowed} = FileManager.build_path(@user_a, "../escape")
    end

    test "rejects user_id containing forward slash" do
      assert {:error, :path_not_allowed} =
               FileManager.write_file("../evil-user", "test.md", "hack")
    end

    test "rejects user_id containing backslash" do
      assert {:error, :path_not_allowed} =
               FileManager.write_file("evil\\user", "test.md", "hack")
    end

    test "rejects user_id containing .." do
      assert {:error, :path_not_allowed} =
               FileManager.write_file("user..escape", "test.md", "hack")
    end
  end

  # ---------------------------------------------------------------
  # Symlink rejection (SECURITY)
  # ---------------------------------------------------------------

  describe "symlink rejection" do
    test "rejects symlinks in path", %{tmp_base: tmp_base} do
      # Create a real file outside user workspace
      outside_dir = Path.join(tmp_base, "outside")
      File.mkdir_p!(outside_dir)
      outside_file = Path.join(outside_dir, "secret.txt")
      File.write!(outside_file, "secret data")

      # Create user dir and a symlink inside it
      user_dir = Path.join(tmp_base, @user_a)
      File.mkdir_p!(user_dir)
      symlink_path = Path.join(user_dir, "link.txt")

      case File.ln_s(outside_file, symlink_path) do
        :ok ->
          # Should reject reading through the symlink
          assert {:error, :path_not_allowed} = FileManager.read_file(@user_a, "link.txt")

        {:error, :enotsup} ->
          # Symlinks not supported on this filesystem — skip
          :ok
      end
    end
  end

  # ---------------------------------------------------------------
  # Per-user isolation
  # ---------------------------------------------------------------

  describe "per-user isolation" do
    test "user A cannot access user B's files" do
      # Write a file for user A
      assert {:ok, _} = FileManager.write_file(@user_a, "private.md", "A's secret")

      # User B should not see it (different directory)
      assert {:error, :enoent} = FileManager.read_file(@user_b, "private.md")
    end

    test "users get separate directories" do
      assert {:ok, _} = FileManager.write_file(@user_a, "shared_name.md", "A content")
      assert {:ok, _} = FileManager.write_file(@user_b, "shared_name.md", "B content")

      assert {:ok, "A content"} = FileManager.read_file(@user_a, "shared_name.md")
      assert {:ok, "B content"} = FileManager.read_file(@user_b, "shared_name.md")
    end
  end

  # ---------------------------------------------------------------
  # delete_file/2
  # ---------------------------------------------------------------

  describe "delete_file/2" do
    test "removes existing file" do
      assert {:ok, _} = FileManager.write_file(@user_a, "to_delete.md", "bye")
      assert :ok = FileManager.delete_file(@user_a, "to_delete.md")
      assert {:error, :enoent} = FileManager.read_file(@user_a, "to_delete.md")
    end

    test "returns :ok for nonexistent file" do
      assert :ok = FileManager.delete_file(@user_a, "never_existed.md")
    end
  end

  # ---------------------------------------------------------------
  # rename_file/3
  # ---------------------------------------------------------------

  describe "rename_file/3" do
    test "moves file within workspace" do
      assert {:ok, _} = FileManager.write_file(@user_a, "old_name.md", "content")
      assert :ok = FileManager.rename_file(@user_a, "old_name.md", "new_name.md")

      assert {:error, :enoent} = FileManager.read_file(@user_a, "old_name.md")
      assert {:ok, "content"} = FileManager.read_file(@user_a, "new_name.md")
    end

    test "moves file to subdirectory" do
      assert {:ok, _} = FileManager.write_file(@user_a, "flat.md", "data")
      assert :ok = FileManager.rename_file(@user_a, "flat.md", "sub/nested.md")
      assert {:ok, "data"} = FileManager.read_file(@user_a, "sub/nested.md")
    end

    test "rejects traversal in source path" do
      assert {:error, :path_not_allowed} =
               FileManager.rename_file(@user_a, "../escape.md", "safe.md")
    end

    test "rejects traversal in destination path" do
      assert {:ok, _} = FileManager.write_file(@user_a, "source.md", "data")

      assert {:error, :path_not_allowed} =
               FileManager.rename_file(@user_a, "source.md", "../escape.md")
    end
  end

  # ---------------------------------------------------------------
  # list_files/1
  # ---------------------------------------------------------------

  describe "list_files/1" do
    test "returns relative paths" do
      assert {:ok, _} = FileManager.write_file(@user_a, "a.md", "data")
      assert {:ok, _} = FileManager.write_file(@user_a, "sub/b.csv", "data")

      assert {:ok, files} = FileManager.list_files(@user_a)
      assert Enum.sort(files) == ["a.md", "sub/b.csv"]
    end

    test "returns empty list for nonexistent user" do
      assert {:ok, []} = FileManager.list_files("nonexistent-user")
    end
  end

  # ---------------------------------------------------------------
  # checksum/1
  # ---------------------------------------------------------------

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

  # ---------------------------------------------------------------
  # ensure_user_dir/1
  # ---------------------------------------------------------------

  describe "ensure_user_dir/1" do
    test "creates user directory", %{tmp_base: tmp_base} do
      user_id = "ensure-dir-test-user"
      assert :ok = FileManager.ensure_user_dir(user_id)
      assert File.dir?(Path.join(tmp_base, user_id))
    end

    test "is idempotent" do
      assert :ok = FileManager.ensure_user_dir(@user_a)
      assert :ok = FileManager.ensure_user_dir(@user_a)
    end
  end

  # ---------------------------------------------------------------
  # build_path/2
  # ---------------------------------------------------------------

  describe "build_path/2" do
    test "returns full path for valid relative path", %{tmp_base: tmp_base} do
      assert {:ok, full_path} = FileManager.build_path(@user_a, "test.md")
      expected = Path.join([tmp_base, @user_a, "test.md"]) |> Path.expand()
      assert full_path == expected
    end

    test "rejects unsafe paths" do
      assert {:error, :path_not_allowed} = FileManager.build_path(@user_a, "/etc/passwd")
      assert {:error, :path_not_allowed} = FileManager.build_path(@user_a, "../escape")
    end
  end
end
