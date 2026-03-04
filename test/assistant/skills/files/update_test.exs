defmodule Assistant.Skills.Files.UpdateTest do
  use ExUnit.Case, async: false

  alias Assistant.Skills.Files.Update
  alias Assistant.Skills.Result

  defmodule FakeDrive do
    def read_file(_token, _file_id), do: {:ok, "hello world"}

    def get_file(_token, _file_id) do
      {:ok,
       %{
         id: "file-1",
         modified_time: "2026-03-04T10:00:00Z",
         md5_checksum: "abc123",
         version: "42"
       }}
    end

    def update_file_content(_token, file_id, updated) do
      send(self(), {:update4, file_id, updated})
      {:ok, %{id: file_id, name: "Example.txt"}}
    end

    def update_file_content(_token, file_id, updated, _mime_type, opts) do
      send(self(), {:update5, file_id, updated, opts})

      case Process.get(:fake_drive_mode) do
        :conflict -> {:error, :conflict}
        _ -> {:ok, %{id: file_id, name: "Example.txt"}}
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

  test "uses legacy update path when conflict protection flag is off" do
    Application.put_env(:assistant, :google_write_conflict_protection, false)

    context = %{
      integrations: %{drive: FakeDrive},
      metadata: %{google_token: "token"}
    }

    {:ok, %Result{status: :ok} = result} =
      Update.execute(%{"id" => "file-1", "search" => "hello", "replace" => "hi"}, context)

    assert result.content =~ "Updated Example.txt"
    assert_received {:update4, "file-1", "hi world"}
    refute_received {:update5, _, _, _}
  end

  test "passes write preconditions when conflict protection flag is on" do
    Application.put_env(:assistant, :google_write_conflict_protection, true)

    context = %{
      integrations: %{drive: FakeDrive},
      metadata: %{google_token: "token"}
    }

    {:ok, %Result{status: :ok}} =
      Update.execute(%{"id" => "file-1", "search" => "hello", "replace" => "hi"}, context)

    assert_received {:update5, "file-1", "hi world", opts}
    assert opts[:expected_modified_time] == "2026-03-04T10:00:00Z"
    assert opts[:expected_checksum] == "abc123"
    assert opts[:expected_version] == "42"
  end

  test "returns conflict-safe error message when precondition conflict occurs" do
    Application.put_env(:assistant, :google_write_conflict_protection, true)
    Process.put(:fake_drive_mode, :conflict)

    context = %{
      integrations: %{drive: FakeDrive},
      metadata: %{google_token: "token"}
    }

    {:ok, %Result{status: :error, content: content}} =
      Update.execute(%{"id" => "file-1", "search" => "hello", "replace" => "hi"}, context)

    assert content =~ "This file changed while I was editing"
  end
end
