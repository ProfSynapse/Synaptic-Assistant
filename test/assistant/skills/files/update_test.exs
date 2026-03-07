defmodule Assistant.Skills.Files.UpdateTest do
  use ExUnit.Case, async: true

  alias Assistant.Skills.Files.Update
  alias Assistant.Skills.Result

  defmodule FakeFileManager do
    def read_file(_user_id, _path) do
      case Process.get(:fake_file_content) do
        nil -> {:error, :enoent}
        content -> {:ok, content}
      end
    end

    def write_file(_user_id, path, content) do
      send(self(), {:write_file, path, content})

      case Process.get(:fake_fm_mode) do
        :write_error -> {:error, :enoent}
        _ -> {:ok, path}
      end
    end

    def checksum(content) do
      :crypto.hash(:sha256, content)
      |> Base.encode16(case: :lower)
      |> String.slice(0, 16)
    end
  end

  defmodule FakeStateStore do
    def get_synced_file_by_local_path(user_id, path) do
      send(self(), {:get_by_path, user_id, path})

      case Process.get(:fake_synced_file) do
        nil -> nil
        file -> file
      end
    end

    def get_synced_file(user_id, drive_file_id) do
      send(self(), {:get_by_id, user_id, drive_file_id})

      case Process.get(:fake_synced_file) do
        nil -> nil
        file -> file
      end
    end

    def update_synced_file(synced_file, attrs) do
      send(self(), {:update_synced_file, synced_file.id, attrs})
      {:ok, Map.merge(synced_file, attrs)}
    end
  end

  defp build_context do
    %{
      user_id: "user-1",
      integrations: %{file_manager: FakeFileManager, state_store: FakeStateStore},
      metadata: %{}
    }
  end

  defp fake_synced_file(overrides \\ %{}) do
    Map.merge(
      %{
        id: "sf-1",
        local_path: "docs/example.md",
        drive_file_id: "drive-file-1",
        drive_file_name: "Example.md"
      },
      overrides
    )
  end

  setup do
    Process.delete(:fake_file_content)
    Process.delete(:fake_synced_file)
    Process.delete(:fake_fm_mode)
    :ok
  end

  test "replaces first occurrence by default" do
    Process.put(:fake_synced_file, fake_synced_file())
    Process.put(:fake_file_content, "hello world hello")

    {:ok, %Result{status: :ok} = result} =
      Update.execute(
        %{"path" => "docs/example.md", "search" => "hello", "replace" => "hi"},
        build_context()
      )

    assert result.content =~ "Updated Example.md"
    assert result.content =~ "replaced 1 occurrence"
    assert_received {:write_file, "docs/example.md", "hi world hello"}
  end

  test "replaces all occurrences with --all flag" do
    Process.put(:fake_synced_file, fake_synced_file())
    Process.put(:fake_file_content, "hello world hello")

    {:ok, %Result{status: :ok} = result} =
      Update.execute(
        %{"path" => "docs/example.md", "search" => "hello", "replace" => "hi", "all" => true},
        build_context()
      )

    assert result.content =~ "replaced 2 occurrence"
    assert_received {:write_file, "docs/example.md", "hi world hi"}
  end

  test "returns unchanged when pattern not found" do
    Process.put(:fake_synced_file, fake_synced_file())
    Process.put(:fake_file_content, "hello world")

    {:ok, %Result{status: :ok, content: content}} =
      Update.execute(
        %{"path" => "docs/example.md", "search" => "missing", "replace" => "x"},
        build_context()
      )

    assert content =~ "No changes made"
    refute_received {:write_file, _, _}
  end

  test "marks file as local_ahead after update" do
    Process.put(:fake_synced_file, fake_synced_file())
    Process.put(:fake_file_content, "hello world")

    {:ok, %Result{status: :ok}} =
      Update.execute(
        %{"path" => "docs/example.md", "search" => "hello", "replace" => "hi"},
        build_context()
      )

    assert_received {:update_synced_file, "sf-1", %{sync_status: "local_ahead"}}
  end

  test "resolves file by Drive file ID" do
    Process.put(:fake_synced_file, fake_synced_file())
    Process.put(:fake_file_content, "hello world")

    {:ok, %Result{status: :ok}} =
      Update.execute(
        %{"id" => "drive-file-1", "search" => "hello", "replace" => "hi"},
        build_context()
      )

    assert_received {:get_by_id, "user-1", "drive-file-1"}
    assert_received {:write_file, "docs/example.md", "hi world"}
  end

  test "returns error when search param is missing" do
    {:ok, %Result{status: :error, content: content}} =
      Update.execute(%{"path" => "docs/example.md", "replace" => "hi"}, build_context())

    assert content =~ "Missing required parameter: --search"
  end

  test "returns error when replace param is missing" do
    {:ok, %Result{status: :error, content: content}} =
      Update.execute(%{"path" => "docs/example.md", "search" => "hello"}, build_context())

    assert content =~ "Missing required parameter: --replace"
  end

  test "returns error when user_id is nil" do
    context = %{user_id: nil, integrations: %{}, metadata: %{}}

    {:ok, %Result{status: :error, content: content}} =
      Update.execute(
        %{"path" => "docs/example.md", "search" => "hello", "replace" => "hi"},
        context
      )

    assert content =~ "User context is required"
  end

  test "returns error when file not found" do
    {:ok, %Result{status: :error, content: content}} =
      Update.execute(
        %{"path" => "missing.md", "search" => "hello", "replace" => "hi"},
        build_context()
      )

    assert content =~ "File not found"
  end
end
