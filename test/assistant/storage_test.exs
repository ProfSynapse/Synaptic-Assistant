defmodule Assistant.StorageTest do
  use Assistant.DataCase, async: true

  alias Assistant.Auth.TokenStore
  alias Assistant.Storage
  alias Assistant.Storage.Providers.GoogleDrive
  alias Assistant.Schemas.User

  setup do
    user =
      %User{}
      |> User.changeset(%{
        external_id: "storage-#{System.unique_integer([:positive])}",
        channel: "test"
      })
      |> Repo.insert!()

    %{user: user}
  end

  describe "connected sources" do
    test "connect_source persists provider-neutral source", %{user: user} do
      assert {:ok, source} =
               Storage.connect_source(user.id, %{
                 provider: "google_drive",
                 source_id: "personal",
                 source_name: "My Drive",
                 source_type: "personal",
                 enabled: true
               })

      assert source.provider == "google_drive"
      assert source.source_id == "personal"
      assert [%{source_name: "My Drive"}] = Storage.list_connected_sources(user.id)
    end
  end

  describe "storage scopes" do
    test "upsert_scope persists neutral scope", %{user: user} do
      assert {:ok, scope} =
               Storage.upsert_scope(%{
                 user_id: user.id,
                 provider: "google_drive",
                 source_id: "drive_123",
                 node_id: "folder_123",
                 node_type: "container",
                 scope_type: Storage.container_scope_type(),
                 label: "Roadmap",
                 access_level: "read_write",
                 scope_effect: "include"
               })

      assert scope.scope_type == "container"
      assert scope.node_id == "folder_123"
      assert [%{label: "Roadmap"}] = Storage.list_scopes(user.id, provider: "google_drive")
    end
  end

  describe "google provider" do
    setup %{user: user} do
      Application.put_env(:assistant, :google_drive_module, Assistant.StorageTest.GoogleDriveMock)

      {:ok, _token} =
        TokenStore.upsert_google_token(user.id, %{
          refresh_token: "refresh-token",
          access_token: "access-token",
          token_expires_at: DateTime.add(DateTime.utc_now(), 3600, :second),
          provider_email: "user@example.com"
        })

      on_exit(fn ->
        Application.delete_env(:assistant, :google_drive_module)
      end)

      :ok
    end

    test "list_sources returns personal and shared sources", %{user: user} do
      assert {:ok, sources} = GoogleDrive.list_sources(user.id, [])

      assert Enum.any?(sources, &(&1.source_id == "personal" and &1.source_type == "personal"))
      assert Enum.any?(sources, &(&1.source_id == "shared-1" and &1.label == "Engineering"))
    end

    test "list_children normalizes node kinds", %{user: user} do
      source = %Assistant.Storage.Source{
        provider: :google_drive,
        source_id: "shared-1",
        source_type: "shared",
        label: "Engineering"
      }

      assert {:ok, %{items: items, complete?: true, next_cursor: nil}} =
               GoogleDrive.list_children(user.id, source, :root, [])

      assert Enum.any?(items, &(&1.node_type == :container and &1.node_id == "folder-1"))
      assert Enum.any?(items, &(&1.node_type == :file and &1.file_kind == "doc"))
      assert Enum.any?(items, &(&1.node_type == :file and &1.file_kind == "sheet"))
    end
  end
end

defmodule Assistant.StorageTest.GoogleDriveMock do
  def list_shared_drives(_access_token) do
    {:ok, [%{id: "shared-1", name: "Engineering"}]}
  end

  def list_files(_access_token, "'shared-1' in parents and trashed=false", _opts) do
    {:ok,
     [
       %{
         id: "folder-1",
         name: "Docs",
         mime_type: "application/vnd.google-apps.folder",
         parents: ["shared-1"]
       },
       %{
         id: "doc-1",
         name: "notes.md",
         mime_type: "text/markdown",
         parents: ["shared-1"]
       },
       %{
         id: "sheet-1",
         name: "budget.csv",
         mime_type: "text/csv",
         parents: ["shared-1"]
       }
     ]}
  end
end
