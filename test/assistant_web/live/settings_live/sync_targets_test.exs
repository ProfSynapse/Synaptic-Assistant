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

  test "drive settings component renders sync targets section" do
    html =
      render_component(&AssistantWeb.Components.DriveSettings.drive_settings/1,
        connected_drives: [
          %{
            id: "drive-row-1",
            drive_type: "personal",
            drive_name: "My Drive",
            drive_id: nil,
            enabled: true
          }
        ],
        available_drives: [],
        drives_loading: false,
        has_google_token: true,
        sync_scopes: [
          %{drive_id: nil, folder_name: "Projects", access_level: "read_write"}
        ]
      )

    assert html =~ "Google Drive Access"
    assert html =~ "Sync Targets"
    assert html =~ "Projects"
    assert html =~ "My Drive"
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
