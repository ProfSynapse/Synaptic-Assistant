defmodule Assistant.Sync.StorageBridgeTest do
  use Assistant.DataCase, async: true

  alias Assistant.ConnectedDrives
  alias Assistant.Repo
  alias Assistant.Schemas.User
  alias Assistant.Storage
  alias Assistant.Sync.StateStore
  alias Assistant.Sync.StorageBridge

  setup do
    user = insert_user("storage-bridge")
    %{user: user}
  end

  describe "reconcile_source/3" do
    test "seeds a personal cursor and enables the legacy drive row", %{user: user} do
      {:ok, _source} =
        Storage.connect_source(user.id, %{
          provider: "google_drive",
          source_id: "personal",
          source_name: "My Drive",
          source_type: "personal",
          enabled: true
        })

      assert {:ok, %{active?: true, scope_count: 0}} =
               StorageBridge.reconcile_source(user.id, "personal",
                 access_token: "token",
                 drive_changes_module: __MODULE__.FakeChanges
               )

      drive = Enum.find(ConnectedDrives.list_for_user(user.id), &(&1.drive_id == nil))
      assert drive.drive_type == "personal"
      assert drive.enabled == true

      cursor = StateStore.get_cursor(user.id, nil)
      assert cursor.start_page_token == "personal-token"
      assert StateStore.list_scopes(user.id, drive_id: :personal) == []
    end

    test "mirrors scoped access and keeps the cursor alive for a shared drive", %{user: user} do
      {:ok, _source} =
        Storage.connect_source(user.id, %{
          provider: "google_drive",
          source_id: "drive-123",
          source_name: "Engineering",
          source_type: "shared",
          enabled: false
        })

      {:ok, _folder_scope} =
        Storage.upsert_scope(%{
          user_id: user.id,
          provider: "google_drive",
          source_id: "drive-123",
          node_id: "folder-1",
          parent_node_id: nil,
          node_type: "container",
          scope_type: "container",
          scope_effect: "include",
          access_level: "read_write",
          label: "Projects"
        })

      {:ok, _file_scope} =
        Storage.upsert_scope(%{
          user_id: user.id,
          provider: "google_drive",
          source_id: "drive-123",
          node_id: "file-1",
          parent_node_id: "folder-1",
          node_type: "file",
          scope_type: "file",
          scope_effect: "exclude",
          access_level: "read_only",
          label: "Roadmap",
          mime_type: "application/pdf",
          file_kind: "pdf"
        })

      assert {:ok, %{active?: true, scope_count: 2}} =
               StorageBridge.reconcile_source(user.id, "drive-123",
                 access_token: "token",
                 drive_changes_module: __MODULE__.FakeChanges
               )

      drive = Enum.find(ConnectedDrives.list_for_user(user.id), &(&1.drive_id == "drive-123"))
      assert drive.drive_type == "shared"
      assert drive.enabled == false

      cursor = StateStore.get_cursor(user.id, "drive-123")
      assert cursor.start_page_token == "shared-token"

      legacy_scopes = StateStore.list_scopes(user.id, drive_id: "drive-123")
      assert Enum.any?(legacy_scopes, &(&1.scope_type == "folder" and &1.folder_id == "folder-1"))
      assert Enum.any?(legacy_scopes, &(&1.scope_type == "file" and &1.file_id == "file-1"))
      assert Enum.any?(legacy_scopes, &(&1.scope_effect == "exclude"))
    end

    test "clears legacy cursors and scopes when a source loses all access", %{user: user} do
      {:ok, _source} =
        Storage.connect_source(user.id, %{
          provider: "google_drive",
          source_id: "drive-123",
          source_name: "Engineering",
          source_type: "shared",
          enabled: false
        })

      {:ok, _scope} =
        Storage.upsert_scope(%{
          user_id: user.id,
          provider: "google_drive",
          source_id: "drive-123",
          node_id: "folder-1",
          parent_node_id: nil,
          node_type: "container",
          scope_type: "container",
          scope_effect: "include",
          access_level: "read_write",
          label: "Projects"
        })

      assert {:ok, %{active?: true}} =
               StorageBridge.reconcile_source(user.id, "drive-123",
                 access_token: "token",
                 drive_changes_module: __MODULE__.FakeChanges
               )

      assert StateStore.get_cursor(user.id, "drive-123") != nil
      assert length(StateStore.list_scopes(user.id, drive_id: "drive-123")) == 1

      source_row = Storage.get_connected_source(user.id, "google_drive", "drive-123")
      {:ok, _updated_source} = Storage.toggle_connected_source(source_row.id, false)

      for scope <- Storage.list_scopes(user.id, provider: "google_drive", source_id: "drive-123") do
        assert {:ok, _} = Storage.delete_scope(scope)
      end

      assert {:ok, %{active?: false, scope_count: 0}} =
               StorageBridge.reconcile_source(user.id, "drive-123",
                 drive_changes_module: __MODULE__.FakeChanges
               )

      assert nil == StateStore.get_cursor(user.id, "drive-123")
      assert [] = StateStore.list_scopes(user.id, drive_id: "drive-123")

      drive = Enum.find(ConnectedDrives.list_for_user(user.id), &(&1.drive_id == "drive-123"))
      assert drive.enabled == false
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

  defmodule FakeChanges do
    def get_start_page_token(_access_token, opts \\ []) do
      case Keyword.get(opts, :drive_id) do
        nil -> {:ok, "personal-token"}
        "drive-123" -> {:ok, "shared-token"}
        other -> {:ok, "#{other}-token"}
      end
    end
  end
end
