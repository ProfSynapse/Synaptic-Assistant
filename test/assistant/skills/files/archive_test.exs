defmodule Assistant.Skills.Files.ArchiveTest do
  use Assistant.DataCase, async: false
  @moduletag :external

  alias Assistant.Skills.Files.Archive
  alias Assistant.Skills.Result

  defmodule FakeFileManager do
    def delete_file(_user_id, path) do
      send(self(), {:delete_file, path})

      case Process.get(:fake_fm_mode) do
        :path_not_allowed -> {:error, :path_not_allowed}
        _ -> :ok
      end
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
  end

  defp build_context do
    user_id = Ecto.UUID.generate()

    %{
      user_id: user_id,
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
    Process.delete(:fake_fm_mode)
    Process.delete(:fake_synced_file)
    :ok
  end

  test "archives file by path — deletes locally and enqueues upstream trash" do
    Process.put(:fake_synced_file, fake_synced_file())

    context = build_context()
    user_id = context.user_id

    {:ok, %Result{status: :ok} = result} =
      Archive.execute(%{"path" => "docs/example.md"}, context)

    assert result.content =~ "Archived 'Example.md'"
    assert result.side_effects == [:file_archived]
    assert_received {:get_by_path, ^user_id, "docs/example.md"}
    assert_received {:delete_file, "docs/example.md"}
  end

  test "archives file by Drive file ID" do
    Process.put(:fake_synced_file, fake_synced_file())

    context = build_context()
    user_id = context.user_id

    {:ok, %Result{status: :ok} = result} = Archive.execute(%{"id" => "drive-file-1"}, context)

    assert result.content =~ "Archived 'Example.md'"
    assert_received {:get_by_id, ^user_id, "drive-file-1"}
    assert_received {:delete_file, "docs/example.md"}
  end

  test "returns error when file not found by path" do
    {:ok, %Result{status: :error, content: content}} =
      Archive.execute(%{"path" => "missing.md"}, build_context())

    assert content =~ "File not found"
  end

  test "returns error when neither path nor id is provided" do
    {:ok, %Result{status: :error, content: content}} =
      Archive.execute(%{}, build_context())

    assert content =~ "Missing required parameter"
  end

  test "returns error when user_id is nil" do
    context = %{user_id: nil, integrations: %{}, metadata: %{}}

    {:ok, %Result{status: :error, content: content}} =
      Archive.execute(%{"path" => "docs/example.md"}, context)

    assert content =~ "User context is required"
  end

  test "returns error for path traversal" do
    Process.put(:fake_synced_file, fake_synced_file())
    Process.put(:fake_fm_mode, :path_not_allowed)

    {:ok, %Result{status: :error, content: content}} =
      Archive.execute(%{"path" => "docs/example.md"}, build_context())

    assert content =~ "directory traversal"
  end
end
