defmodule Assistant.Sync.Workers.UpstreamSyncWorkerTest do
  use Assistant.DataCase, async: false

  alias Assistant.Auth.TokenStore
  alias Assistant.Sync.StateStore
  alias Assistant.Sync.Workers.UpstreamSyncWorker
  alias Assistant.Sync.Workers.UpstreamSyncWorkerDriveMock

  setup do
    prev_drive_module = Application.get_env(:assistant, :google_drive_module)
    Application.put_env(:assistant, :google_drive_module, UpstreamSyncWorkerDriveMock)

    user =
      %Assistant.Schemas.User{}
      |> Assistant.Schemas.User.changeset(%{
        external_id: "upstream-worker-#{System.unique_integer([:positive])}",
        channel: "test"
      })
      |> Repo.insert!()

    {:ok, _token} =
      TokenStore.upsert_google_token(user.id, %{
        refresh_token: "refresh-token",
        access_token: "access-token",
        token_expires_at: DateTime.add(DateTime.utc_now(), 3600, :second),
        provider_email: "user@example.com"
      })

    {:ok, synced_file} =
      StateStore.create_synced_file(%{
        user_id: user.id,
        drive_file_id: "drive-file-1",
        drive_file_name: "example.md",
        drive_mime_type: "text/plain",
        local_path: "example.md",
        local_format: "md",
        content: "Hello from the synced workspace",
        remote_modified_at: ~U[2026-03-19 08:30:00Z],
        remote_checksum: "remote-old",
        local_checksum: "local-old",
        sync_status: "local_ahead"
      })

    on_exit(fn ->
      UpstreamSyncWorkerDriveMock.reset()

      if is_nil(prev_drive_module) do
        Application.delete_env(:assistant, :google_drive_module)
      else
        Application.put_env(:assistant, :google_drive_module, prev_drive_module)
      end
    end)

    %{user: user, synced_file: synced_file}
  end

  test "write_intent pushes local content, marks synced_file synced, and records success history",
       %{
         user: user
       } do
    intent_id = "intent-1"

    assert :ok =
             UpstreamSyncWorker.perform(%Oban.Job{
               args: %{
                 "action" => "write_intent",
                 "user_id" => user.id,
                 "drive_file_id" => "drive-file-1",
                 "intent_id" => intent_id
               }
             })

    assert [
             {:update_file_content, "access-token", "drive-file-1",
              "Hello from the synced workspace", "text/plain", opts}
           ] = UpstreamSyncWorkerDriveMock.calls()

    assert %DateTime{} = opts[:expected_modified_time]
    assert DateTime.compare(opts[:expected_modified_time], ~U[2026-03-19 08:30:00Z]) == :eq

    synced = StateStore.get_synced_file(user.id, "drive-file-1")
    assert synced.sync_status == "synced"
    assert synced.last_synced_at != nil
    assert DateTime.compare(synced.remote_modified_at, ~U[2026-03-19 09:30:00Z]) == :eq
    assert synced.remote_checksum == "mock-md5"

    history = StateStore.list_history(synced.id)

    assert Enum.any?(history, fn entry ->
             details = entry.details || %{}
             details["intent_id"] == intent_id and details["event_type"] == "success"
           end)
  end

  test "write_intent replay is idempotent and does not duplicate success history", %{user: user} do
    intent_id = "intent-replay"

    assert :ok =
             UpstreamSyncWorker.perform(%Oban.Job{
               args: %{
                 "action" => "write_intent",
                 "user_id" => user.id,
                 "drive_file_id" => "drive-file-1",
                 "intent_id" => intent_id
               }
             })

    assert :ok =
             UpstreamSyncWorker.perform(%Oban.Job{
               args: %{
                 "action" => "write_intent",
                 "user_id" => user.id,
                 "drive_file_id" => "drive-file-1",
                 "intent_id" => intent_id
               }
             })

    synced = StateStore.get_synced_file(user.id, "drive-file-1")

    success_entries =
      synced.id
      |> StateStore.list_history()
      |> Enum.filter(fn entry ->
        details = entry.details || %{}
        details["intent_id"] == intent_id and details["event_type"] == "success"
      end)

    assert length(success_entries) == 1
    assert length(UpstreamSyncWorkerDriveMock.calls()) == 1
  end

  test "write_intent records conflict and does not keep retrying a stale remote change", %{
    user: user
  } do
    Process.put(:upstream_drive_update_result, {:error, :conflict})

    intent_id = "intent-conflict"

    assert {:discard, :conflict} =
             UpstreamSyncWorker.perform(%Oban.Job{
               args: %{
                 "action" => "write_intent",
                 "user_id" => user.id,
                 "drive_file_id" => "drive-file-1",
                 "intent_id" => intent_id
               }
             })

    synced = StateStore.get_synced_file(user.id, "drive-file-1")
    assert synced.sync_status == "conflict"
    assert synced.sync_error == "Remote file changed before upstream sync"

    history = StateStore.list_history(synced.id)

    assert Enum.any?(history, fn entry ->
             details = entry.details || %{}
             details["intent_id"] == intent_id and details["event_type"] == "failure"
           end)
  end

  test "trash action trashes the remote file and keeps local state synced", %{user: user} do
    assert :ok =
             UpstreamSyncWorker.perform(%Oban.Job{
               args: %{
                 "action" => "trash",
                 "user_id" => user.id,
                 "drive_file_id" => "drive-file-1"
               }
             })

    assert [
             {:trash_file, "access-token", "drive-file-1", opts}
           ] = UpstreamSyncWorkerDriveMock.calls()

    assert %DateTime{} = opts[:expected_modified_time]
    assert DateTime.compare(opts[:expected_modified_time], ~U[2026-03-19 08:30:00Z]) == :eq

    synced = StateStore.get_synced_file(user.id, "drive-file-1")
    assert synced.sync_status == "synced"
    assert synced.last_synced_at != nil
    assert DateTime.compare(synced.remote_modified_at, ~U[2026-03-19 09:30:00Z]) == :eq
  end
end
