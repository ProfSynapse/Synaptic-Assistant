defmodule Assistant.Sync.Workers.FileSyncWorkerTest do
  use Assistant.DataCase, async: false

  alias Assistant.Repo
  alias Assistant.Schemas.SyncedFile
  alias Assistant.Schemas.User
  alias Assistant.Sync.StateStore
  alias Assistant.Sync.Workers.FileSyncWorker

  setup do
    previous_auth_fun = Application.get_env(:assistant, :sync_google_auth_fun)
    previous_converter_fun = Application.get_env(:assistant, :sync_google_converter_fun)

    on_exit(fn ->
      restore_env(:sync_google_auth_fun, previous_auth_fun)
      restore_env(:sync_google_converter_fun, previous_converter_fun)
    end)

    user = insert_user("file-sync-worker")
    %{user: user}
  end

  test "imports a new Drive file without a serialized access token", %{user: user} do
    Application.put_env(:assistant, :sync_google_auth_fun, fn user_id ->
      send(self(), {:auth_lookup, user_id})
      {:ok, "access-token-1"}
    end)

    Application.put_env(:assistant, :sync_google_converter_fun, fn access_token, file_id, mime ->
      send(self(), {:convert, access_token, file_id, mime})
      {:ok, {"# imported report\n", "md"}}
    end)

    job = %Oban.Job{
      args: %{
        "action" => "upsert",
        "user_id" => user.id,
        "drive_id" => nil,
        "drive_file_id" => "drive-file-1",
        "change" => %{
          "file_id" => "drive-file-1",
          "name" => "Report",
          "mime_type" => "application/vnd.google-apps.document",
          "modified_time" => "2026-03-19T09:00:00Z",
          "size" => "42",
          "parents" => ["root"]
        }
      }
    }

    assert :ok = FileSyncWorker.perform(job)
    assert_received {:auth_lookup, auth_user_id}
    assert auth_user_id == user.id

    assert_received {:convert, "access-token-1", "drive-file-1",
                     "application/vnd.google-apps.document"}

    synced_file = StateStore.get_synced_file(user.id, "drive-file-1")
    assert %SyncedFile{} = synced_file
    assert synced_file.drive_file_name == "Report"
    assert synced_file.local_path == "Report.md"
    assert synced_file.local_format == "md"
    assert synced_file.sync_status == "synced"
    assert synced_file.content == "# imported report\n"
    assert synced_file.remote_modified_at == ~U[2026-03-19 09:00:00.000000Z]
    assert synced_file.file_size == 42
  end

  test "updates an existing synced file in place and preserves its local path", %{user: user} do
    {:ok, synced_file} =
      StateStore.create_synced_file(%{
        user_id: user.id,
        drive_file_id: "drive-file-2",
        drive_file_name: "Original Report",
        drive_mime_type: "text/plain",
        local_path: "docs/original-report.md",
        local_format: "md",
        sync_status: "synced",
        content: "old content",
        remote_modified_at: ~U[2026-03-18 09:00:00Z],
        local_modified_at: ~U[2026-03-18 09:00:00Z],
        remote_checksum: "oldchecksum0001",
        local_checksum: "oldchecksum0001",
        last_synced_at: ~U[2026-03-18 09:00:00Z]
      })

    Application.put_env(:assistant, :sync_google_auth_fun, fn _user_id ->
      {:ok, "access-token-2"}
    end)

    Application.put_env(:assistant, :sync_google_converter_fun, fn access_token, file_id, mime ->
      send(self(), {:convert, access_token, file_id, mime})
      {:ok, {"updated content", "md"}}
    end)

    job = %Oban.Job{
      args: %{
        "action" => "upsert",
        "user_id" => user.id,
        "drive_id" => nil,
        "drive_file_id" => synced_file.drive_file_id,
        "change" => %{
          "file_id" => synced_file.drive_file_id,
          "name" => "Renamed Report",
          "mime_type" => "text/plain",
          "modified_time" => "2026-03-19T10:15:00Z",
          "size" => "15",
          "parents" => ["root"]
        }
      }
    }

    assert :ok = FileSyncWorker.perform(job)
    assert_received {:convert, "access-token-2", "drive-file-2", "text/plain"}

    updated = StateStore.get_synced_file(user.id, "drive-file-2")
    assert %SyncedFile{} = updated
    assert updated.id == synced_file.id
    assert updated.local_path == "docs/original-report.md"
    assert updated.drive_file_name == "Renamed Report"
    assert updated.content == "updated content"
    assert updated.sync_status == "synced"
  end

  test "deletes a clean file without auth and preserves a local conflict copy when needed", %{
    user: user
  } do
    {:ok, clean_file} =
      StateStore.create_synced_file(%{
        user_id: user.id,
        drive_file_id: "drive-file-3",
        drive_file_name: "Clean File",
        drive_mime_type: "text/plain",
        local_path: "clean-file.txt",
        local_format: "txt",
        sync_status: "synced",
        content: "clean content"
      })

    {:ok, conflict_file} =
      StateStore.create_synced_file(%{
        user_id: user.id,
        drive_file_id: "drive-file-4",
        drive_file_name: "Conflict File",
        drive_mime_type: "text/plain",
        local_path: "conflict-file.txt",
        local_format: "txt",
        sync_status: "local_ahead",
        content: "changed locally"
      })

    assert :ok =
             FileSyncWorker.perform(%Oban.Job{
               args: %{
                 "action" => "delete",
                 "user_id" => user.id,
                 "drive_file_id" => clean_file.drive_file_id,
                 "change" => %{
                   "file_id" => clean_file.drive_file_id,
                   "name" => "Clean File",
                   "removed" => true
                 }
               }
             })

    assert nil == StateStore.get_synced_file(user.id, clean_file.drive_file_id)

    assert :ok =
             FileSyncWorker.perform(%Oban.Job{
               args: %{
                 "action" => "delete",
                 "user_id" => user.id,
                 "drive_file_id" => conflict_file.drive_file_id,
                 "change" => %{
                   "file_id" => conflict_file.drive_file_id,
                   "name" => "Conflict File",
                   "removed" => true
                 }
               }
             })

    conflicted = StateStore.get_synced_file(user.id, conflict_file.drive_file_id)
    assert %SyncedFile{} = conflicted
    assert conflicted.sync_status == "conflict"
    assert conflicted.content == "changed locally"

    copies =
      StateStore.list_synced_files(user.id)
      |> Enum.filter(&String.starts_with?(&1.drive_file_id, "local-conflict:"))

    assert length(copies) == 1
    [conflict_copy] = copies
    assert conflict_copy.local_path =~ "conflict-file.conflict."
    assert conflict_copy.content == "changed locally"
    assert conflict_copy.sync_status == "conflict"
  end

  test "has moved onto the shared sync queue" do
    assert FileSyncWorker.__opts__()[:queue] == :sync
  end

  defp insert_user(prefix) do
    %User{}
    |> User.changeset(%{
      external_id: "#{prefix}-#{System.unique_integer([:positive])}",
      channel: "test"
    })
    |> Repo.insert!()
  end

  defp restore_env(key, nil), do: Application.delete_env(:assistant, key)
  defp restore_env(key, value), do: Application.put_env(:assistant, key, value)
end
