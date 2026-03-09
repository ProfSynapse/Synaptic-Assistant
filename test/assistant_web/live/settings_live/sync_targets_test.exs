defmodule AssistantWeb.SettingsLive.SyncTargetsTest do
  use AssistantWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Assistant.Accounts
  alias Assistant.Auth.TokenStore
  alias Assistant.Repo
  alias Assistant.Storage
  alias Assistant.Schemas.User

  import Assistant.AccountsFixtures

  test "google workspace drive access component renders drive table" do
    html =
      render_component(
        &AssistantWeb.Components.GoogleWorkspaceDriveAccess.google_workspace_drive_access/1,
        connected_sources: [
          %{
            id: "drive-row-1",
            source_type: "personal",
            source_name: "My Drive",
            source_id: "personal",
            enabled: false
          }
        ],
        available_sources: [],
        sources_loading: false,
        provider_connected: true,
        storage_scopes: [%{source_id: "personal", node_id: "folder-1", scope_type: "container"}],
        selected_source: nil,
        draft_scopes: [],
        nodes: %{},
        root_keys: [],
        expanded: MapSet.new(),
        loading: false,
        loading_nodes: MapSet.new(),
        error: nil,
        dirty: false
      )

    assert html =~ "Drive Access"
    assert html =~ "Full Access"
    assert html =~ "My Drive"
    assert html =~ "1 scoped item"
  end

  test "google workspace detail page loads", %{conn: conn} do
    settings_user = settings_user_fixture(%{email: unique_settings_user_email()})
    user = insert_user("google-workspace-detail")
    link_settings_user(settings_user, user.id)

    {:ok, _source} =
      Storage.connect_source(user.id, %{
        provider: "google_drive",
        source_id: "drive_123",
        source_name: "Engineering",
        source_type: "shared",
        enabled: false
      })

    conn = log_in_settings_user(conn, settings_user)
    {:ok, _lv, html} = live(conn, ~p"/settings/apps/google_workspace")

    assert html =~ "Google Workspace"
    assert html =~ "Personal Tool Access"
  end

  test "scoped tree saves folder include and file exclude scopes from the modal", %{conn: conn} do
    Application.put_env(
      :assistant,
      :google_drive_module,
      AssistantWeb.SettingsLive.SyncTargetsTest.DriveTreeMock
    )

    on_exit(fn ->
      Application.delete_env(:assistant, :google_drive_module)
    end)

    settings_user = settings_user_fixture(%{email: unique_settings_user_email()})
    user = insert_user("drive-tree")
    link_settings_user(settings_user, user.id)

    {:ok, source} =
      Storage.connect_source(user.id, %{
        provider: "google_drive",
        source_id: "drive_123",
        source_name: "Engineering",
        source_type: "shared",
        enabled: false
      })

    {:ok, _token} =
      TokenStore.upsert_google_token(user.id, %{
        refresh_token: "refresh-token",
        access_token: "access-token",
        token_expires_at: DateTime.add(DateTime.utc_now(), 3600, :second),
        provider_email: "user@example.com"
      })

    conn = log_in_settings_user(conn, settings_user)
    {:ok, lv, _html} = live(conn, ~p"/settings/apps/google_workspace")

    html =
      render_click(lv, "open_file_picker", %{
        "id" => source.id,
        "source_id" => "drive_123",
        "source_name" => "Engineering",
        "source_type" => "shared"
      })

    assert html =~ "Manage Engineering"
    assert html =~ "Launch Materials"

    html =
      render_click(lv, "expand_file_picker_node", %{
        "node_key" => "container:launch-folder"
      })

    assert html =~ "Plan"
    assert html =~ "Passwords"

    _html =
      render_click(lv, "toggle_file_picker_node", %{
        "node_key" => "container:launch-folder",
        "node_type" => "container"
      })

    _html =
      render_click(lv, "toggle_file_picker_node", %{
        "node_key" => "file:passwords-file",
        "node_type" => "file"
      })

    _html = render_click(lv, "save_file_picker", %{})

    scopes = Storage.list_scopes(user.id, provider: "google_drive", source_id: "drive_123")

    assert Enum.any?(
             scopes,
             &(&1.scope_type == "container" and &1.node_id == "launch-folder" and
                 &1.scope_effect == "include")
           )

    assert Enum.any?(
             scopes,
             &(&1.scope_type == "file" and &1.node_id == "passwords-file" and
                 &1.scope_effect == "exclude")
           )
  end

  defp insert_user(prefix) do
    %User{}
    |> User.changeset(%{
      external_id: "#{prefix}-#{System.unique_integer([:positive])}",
      channel: "test"
    })
    |> Repo.insert!()
  end

  defp link_settings_user(settings_user, user_id) do
    settings_user
    |> Ecto.Changeset.change(user_id: user_id)
    |> Repo.update!()

    Accounts.get_settings_user!(settings_user.id)
  end
end

defmodule AssistantWeb.SettingsLive.SyncTargetsTest.DriveTreeMock do
  def list_files(_access_token, "'drive_123' in parents and trashed=false", _opts) do
    {:ok,
     [
       %{
         id: "launch-folder",
         name: "Launch Materials",
         mime_type: "application/vnd.google-apps.folder",
         parents: ["drive_123"]
       },
       %{
         id: "overview-file",
         name: "Overview",
         mime_type: "application/pdf",
         parents: ["drive_123"]
       }
     ]}
  end

  def list_files(_access_token, "'launch-folder' in parents and trashed=false", _opts) do
    {:ok,
     [
       %{
         id: "plan-file",
         name: "Plan",
         mime_type: "application/vnd.google-apps.document",
         parents: ["launch-folder"]
       },
       %{
         id: "passwords-file",
         name: "Passwords",
         mime_type: "application/pdf",
         parents: ["launch-folder"]
       }
     ]}
  end

  def list_files(_access_token, _query, _opts), do: {:ok, []}

  def get_file(_access_token, "overview-file") do
    {:ok,
     %{
       id: "overview-file",
       name: "Overview",
       mime_type: "application/pdf",
       parents: ["drive_123"]
     }}
  end

  def get_file(_access_token, "plan-file") do
    {:ok,
     %{
       id: "plan-file",
       name: "Plan",
       mime_type: "application/vnd.google-apps.document",
       parents: ["launch-folder"]
     }}
  end

  def get_file(_access_token, "passwords-file") do
    {:ok,
     %{
       id: "passwords-file",
       name: "Passwords",
       mime_type: "application/pdf",
       parents: ["launch-folder"]
     }}
  end

  def get_file(_access_token, _file_id), do: {:error, :not_found}
end
