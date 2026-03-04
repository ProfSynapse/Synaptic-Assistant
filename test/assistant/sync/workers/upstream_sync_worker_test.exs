defmodule Assistant.Sync.Workers.UpstreamSyncWorkerTest do
  use Assistant.DataCase, async: true

  alias Assistant.Sync.StateStore
  alias Assistant.Sync.Workers.UpstreamSyncWorker

  setup do
    user =
      %Assistant.Schemas.User{}
      |> Assistant.Schemas.User.changeset(%{
        external_id: "upstream-worker-#{System.unique_integer([:positive])}",
        channel: "test"
      })
      |> Repo.insert!()

    {:ok, synced_file} =
      StateStore.create_synced_file(%{
        user_id: user.id,
        drive_file_id: "drive-file-1",
        drive_file_name: "example.md",
        drive_mime_type: "text/plain",
        local_path: "example.md",
        local_format: "md",
        sync_status: "local_ahead"
      })

    %{user: user, synced_file: synced_file}
  end

  test "write_intent marks synced_file as synced and records success history", %{user: user} do
    intent_id = "intent-1"

    assert :ok =
             UpstreamSyncWorker.perform(%Oban.Job{args: %{
               "action" => "write_intent",
               "user_id" => user.id,
               "drive_file_id" => "drive-file-1",
               "intent_id" => intent_id
             }})

    synced = StateStore.get_synced_file(user.id, "drive-file-1")
    assert synced.sync_status == "synced"
    assert synced.last_synced_at != nil

    history = StateStore.list_history(synced.id)

    assert Enum.any?(history, fn entry ->
             details = entry.details || %{}
             details["intent_id"] == intent_id and details["event_type"] == "success"
           end)
  end

  test "write_intent replay is idempotent and does not duplicate success history", %{user: user} do
    intent_id = "intent-replay"

    assert :ok =
             UpstreamSyncWorker.perform(%Oban.Job{args: %{
               "action" => "write_intent",
               "user_id" => user.id,
               "drive_file_id" => "drive-file-1",
               "intent_id" => intent_id
             }})

    assert :ok =
             UpstreamSyncWorker.perform(%Oban.Job{args: %{
               "action" => "write_intent",
               "user_id" => user.id,
               "drive_file_id" => "drive-file-1",
               "intent_id" => intent_id
             }})

    synced = StateStore.get_synced_file(user.id, "drive-file-1")

    success_entries =
      synced.id
      |> StateStore.list_history()
      |> Enum.filter(fn entry ->
        details = entry.details || %{}
        details["intent_id"] == intent_id and details["event_type"] == "success"
      end)

    assert length(success_entries) == 1
  end
end
