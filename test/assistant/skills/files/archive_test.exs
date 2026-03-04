defmodule Assistant.Skills.Files.ArchiveTest do
  use ExUnit.Case, async: false

  alias Assistant.Skills.Files.Archive
  alias Assistant.Skills.Result

  defmodule FakeDrive do
    def get_file(_token, file_id) do
      {:ok,
       %{
         id: file_id,
         name: "Example.txt",
         modified_time: "2026-03-04T10:00:00Z",
         md5_checksum: "abc123",
         version: "42"
       }}
    end

    def move_file(_token, file_id, archive_id) do
      send(self(), {:move3, file_id, archive_id})
      {:ok, %{id: file_id, parents: [archive_id]}}
    end

    def move_file(_token, file_id, archive_id, _remove_parents, opts) do
      send(self(), {:move5, file_id, archive_id, opts})

      case Process.get(:fake_drive_mode) do
        :conflict -> {:error, :conflict}
        _ -> {:ok, %{id: file_id, parents: [archive_id]}}
      end
    end
  end

  setup do
    prev_flag = Application.get_env(:assistant, :google_write_conflict_protection)
    Process.delete(:fake_drive_mode)

    on_exit(fn ->
      if prev_flag == nil do
        Application.delete_env(:assistant, :google_write_conflict_protection)
      else
        Application.put_env(:assistant, :google_write_conflict_protection, prev_flag)
      end

      Process.delete(:fake_drive_mode)
    end)

    :ok
  end

  test "uses legacy move path when conflict protection flag is off" do
    Application.put_env(:assistant, :google_write_conflict_protection, false)

    context = %{
      integrations: %{drive: FakeDrive},
      metadata: %{google_token: "token", enabled_drives: []}
    }

    {:ok, %Result{status: :ok} = result} =
      Archive.execute(%{"id" => "file-1", "folder" => "archive-1"}, context)

    assert result.content =~ "Archived 'Example.txt'"
    assert_received {:move3, "file-1", "archive-1"}
    refute_received {:move5, _, _, _}
  end

  test "passes move preconditions when conflict protection flag is on" do
    Application.put_env(:assistant, :google_write_conflict_protection, true)

    context = %{
      integrations: %{drive: FakeDrive},
      metadata: %{google_token: "token", enabled_drives: []}
    }

    {:ok, %Result{status: :ok}} =
      Archive.execute(%{"id" => "file-1", "folder" => "archive-1"}, context)

    assert_received {:move5, "file-1", "archive-1", opts}
    assert opts[:expected_modified_time] == "2026-03-04T10:00:00Z"
    assert opts[:expected_checksum] == "abc123"
    assert opts[:expected_version] == "42"
  end

  test "returns conflict-safe error message when move conflict occurs" do
    Application.put_env(:assistant, :google_write_conflict_protection, true)
    Process.put(:fake_drive_mode, :conflict)

    context = %{
      integrations: %{drive: FakeDrive},
      metadata: %{google_token: "token", enabled_drives: []}
    }

    {:ok, %Result{status: :error, content: content}} =
      Archive.execute(%{"id" => "file-1", "folder" => "archive-1"}, context)

    assert content =~ "This file changed while I was archiving it"
  end
end
