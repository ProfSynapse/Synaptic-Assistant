defmodule AssistantWeb.SettingsLive.SyncTargetsTest do
  use AssistantWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Assistant.Accounts
  alias Assistant.Auth.TokenStore
  alias Assistant.ConnectedDrives
  alias Assistant.Repo
  alias Assistant.Schemas.User
  alias Assistant.Sync.StateStore

  import Assistant.AccountsFixtures

  test "google workspace drive access component renders drive table" do
    html =
      render_component(
        &AssistantWeb.Components.GoogleWorkspaceDriveAccess.google_workspace_drive_access/1,
        connected_drives: [
          %{
            id: "drive-row-1",
            drive_type: "personal",
            drive_name: "My Drive",
            drive_id: nil,
            enabled: false
          }
        ],
        available_drives: [],
        drives_loading: false,
        has_google_token: true,
        sync_scopes: [%{drive_id: nil, folder_id: "folder-1", scope_type: "folder"}],
        manager_drive: nil,
        manager_scopes: [],
        tree_nodes: %{},
        tree_root_keys: [],
        tree_expanded: MapSet.new(),
        tree_loading: false,
        tree_loading_nodes: MapSet.new(),
        tree_error: nil,
        drive_scope_dirty: false
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

    {:ok, _drive} =
      ConnectedDrives.connect(user.id, %{
        drive_id: "drive_123",
        drive_name: "Engineering",
        drive_type: "shared",
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

    Application.put_env(
      :assistant,
      :google_drive_file_sync_worker_module,
      AssistantWeb.SettingsLive.SyncTargetsTest.FileSyncWorkerMock
    )

    on_exit(fn ->
      Application.delete_env(:assistant, :google_drive_module)
      Application.delete_env(:assistant, :google_drive_file_sync_worker_module)
    end)

    settings_user = settings_user_fixture(%{email: unique_settings_user_email()})
    user = insert_user("drive-tree")
    link_settings_user(settings_user, user.id)

    {:ok, drive} =
      ConnectedDrives.connect(user.id, %{
        drive_id: "drive_123",
        drive_name: "Engineering",
        drive_type: "shared",
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
      render_click(lv, "open_drive_scope_manager", %{
        "id" => drive.id,
        "drive_id" => "drive_123",
        "drive_name" => "Engineering",
        "drive_type" => "shared"
      })

    assert html =~ "Manage Engineering"
    assert html =~ "Launch Materials"

    html =
      render_click(lv, "toggle_drive_tree_node_expanded", %{
        "node_key" => "folder:launch-folder"
      })

    assert html =~ "Plan"
    assert html =~ "Passwords"

    _html =
      render_click(lv, "toggle_drive_tree_node_scope", %{
        "node_key" => "folder:launch-folder",
        "node_type" => "folder"
      })

    refute StateStore.get_synced_file(user.id, "plan-file")
    refute StateStore.get_synced_file(user.id, "passwords-file")
    refute StateStore.get_synced_file(user.id, "overview-file")

    _html =
      render_click(lv, "toggle_drive_tree_node_scope", %{
        "node_key" => "file:passwords-file",
        "node_type" => "file"
      })

    _html = render_click(lv, "save_drive_scope_manager", %{})

    folder_scope = StateStore.get_scope(user.id, "drive_123", "launch-folder")
    assert folder_scope.scope_effect == "include"

    file_scope = StateStore.get_file_scope(user.id, "drive_123", "passwords-file")
    assert file_scope.scope_effect == "exclude"

    assert StateStore.get_synced_file(user.id, "plan-file")
    refute StateStore.get_synced_file(user.id, "passwords-file")
  end

  test "add_sync_target shows auth error when user is linked but Google token is missing", %{
    conn: conn
  } do
    settings_user = settings_user_fixture(%{email: unique_settings_user_email()})
    user = insert_user("sync-targets-auth")
    link_settings_user(settings_user, user.id)

    {:ok, _drive} =
      ConnectedDrives.connect(user.id, %{
        drive_id: "drive_123",
        drive_name: "Engineering",
        drive_type: "shared"
      })

    conn = log_in_settings_user(conn, settings_user)
    {:ok, lv, _html} = live(conn, ~p"/settings/apps")

    html =
      render_click(lv, "add_sync_target", %{
        "drive_id" => "drive_123",
        "folder_id" => "folder_123",
        "folder_name" => "Roadmap"
      })

    assert html =~ "Connect your Google account first."
    assert StateStore.list_scopes(user.id) == []
  end

  test "add_sync_target creates scope and cursor on success", %{conn: conn} do
    Application.put_env(
      :assistant,
      :google_drive_changes_module,
      AssistantWeb.SettingsLive.SyncTargetsTest.ChangesSuccessMock
    )

    on_exit(fn ->
      Application.delete_env(:assistant, :google_drive_changes_module)
    end)

    settings_user = settings_user_fixture(%{email: unique_settings_user_email()})
    user = insert_user("sync-targets-success")
    link_settings_user(settings_user, user.id)

    {:ok, _drive} =
      ConnectedDrives.connect(user.id, %{
        drive_id: "drive_123",
        drive_name: "Engineering",
        drive_type: "shared"
      })

    {:ok, _token} =
      TokenStore.upsert_google_token(user.id, %{
        refresh_token: "refresh-token",
        access_token: "access-token",
        token_expires_at: DateTime.add(DateTime.utc_now(), 3600, :second),
        provider_email: "user@example.com"
      })

    conn = log_in_settings_user(conn, settings_user)
    {:ok, lv, _html} = live(conn, ~p"/settings/apps")

    html =
      render_click(lv, "add_sync_target", %{
        "drive_id" => "drive_123",
        "folder_id" => "folder_123",
        "folder_name" => "Roadmap"
      })

    assert html =~ "Added sync target Roadmap."

    scopes = StateStore.list_scopes(user.id)
    assert Enum.any?(scopes, &(&1.drive_id == "drive_123" and &1.folder_id == "folder_123"))

    cursors = StateStore.list_cursors(user.id)

    assert Enum.any?(
             cursors,
             &(&1.drive_id == "drive_123" and &1.start_page_token == "start-page-token")
           )
  end

  test "add_sync_target shows error when changes token fetch fails", %{conn: conn} do
    Application.put_env(
      :assistant,
      :google_drive_changes_module,
      AssistantWeb.SettingsLive.SyncTargetsTest.ChangesFailureMock
    )

    on_exit(fn ->
      Application.delete_env(:assistant, :google_drive_changes_module)
    end)

    settings_user = settings_user_fixture(%{email: unique_settings_user_email()})
    user = insert_user("sync-targets-changes-failure")
    link_settings_user(settings_user, user.id)

    {:ok, _drive} =
      ConnectedDrives.connect(user.id, %{
        drive_id: "drive_123",
        drive_name: "Engineering",
        drive_type: "shared"
      })

    {:ok, _token} =
      TokenStore.upsert_google_token(user.id, %{
        refresh_token: "refresh-token",
        access_token: "access-token",
        token_expires_at: DateTime.add(DateTime.utc_now(), 3600, :second),
        provider_email: "user@example.com"
      })

    conn = log_in_settings_user(conn, settings_user)
    {:ok, lv, _html} = live(conn, ~p"/settings/apps")

    html =
      render_click(lv, "add_sync_target", %{
        "drive_id" => "drive_123",
        "folder_id" => "folder_123",
        "folder_name" => "Roadmap"
      })

    assert html =~ "Failed to add sync target."
    assert StateStore.list_cursors(user.id) == []
    assert Enum.any?(StateStore.list_scopes(user.id), &(&1.folder_id == "folder_123"))
  end

  test "add_sync_target validates blank folder_name", %{conn: conn} do
    settings_user = settings_user_fixture(%{email: unique_settings_user_email()})
    user = insert_user("sync-targets-blank-name")
    link_settings_user(settings_user, user.id)

    conn = log_in_settings_user(conn, settings_user)
    {:ok, lv, _html} = live(conn, ~p"/settings/apps")

    html =
      render_click(lv, "add_sync_target", %{
        "drive_id" => "drive_123",
        "folder_id" => "folder_123",
        "folder_name" => "   "
      })

    assert html =~ "Folder name is required."
  end

  test "open_sync_target_browser shows guardrail error when no enabled drives exist", %{
    conn: conn
  } do
    settings_user = settings_user_fixture(%{email: unique_settings_user_email()})
    user = insert_user("sync-targets-open-guard")
    link_settings_user(settings_user, user.id)

    conn = log_in_settings_user(conn, settings_user)
    {:ok, lv, _html} = live(conn, ~p"/settings/apps")

    html = render_click(lv, "open_sync_target_browser", %{})
    assert html =~ "Connect and enable at least one drive first."
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

defmodule AssistantWeb.SettingsLive.SyncTargetsTest.ChangesSuccessMock do
  def get_start_page_token(_access_token, _opts), do: {:ok, "start-page-token"}
end

defmodule AssistantWeb.SettingsLive.SyncTargetsTest.ChangesFailureMock do
  def get_start_page_token(_access_token, _opts), do: {:error, :upstream_unavailable}
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

defmodule AssistantWeb.SettingsLive.SyncTargetsTest.FileSyncWorkerMock do
  use Oban.Worker, queue: :google_drive_sync, max_attempts: 1

  alias Assistant.Sync.StateStore

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    change = args["change"] || %{}
    file_id = args["drive_file_id"]
    name = change["name"] || "Synced"
    mime_type = change["mime_type"] || "application/octet-stream"

    {:ok, _record} =
      StateStore.create_synced_file(%{
        user_id: args["user_id"],
        drive_id: args["drive_id"],
        drive_file_id: file_id,
        drive_file_name: name,
        drive_mime_type: mime_type,
        local_path: "#{file_id}.bin",
        local_format: "bin",
        sync_status: "synced",
        content: "synced"
      })

    :ok
  end
end
