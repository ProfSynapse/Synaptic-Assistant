defmodule Assistant.Sync.Workers.UpstreamSyncWorker do
  @moduledoc """
  Handles pushing local modifications (from the agent's sandbox changes)
  back to the Google Drive API.

  When a SyncedFile is marked as `local_ahead`, this worker converts the
  content if necessary and updates/creates the file in Google Drive.
  """
  use Oban.Worker,
    queue: :google_drive_sync,
    max_attempts: 7

  require Logger

  alias Assistant.Repo
  alias Assistant.Schemas.SyncedFile
  alias Assistant.Sync.StateStore

  @impl Oban.Worker
  def perform(%Oban.Job{
        args: %{"action" => "trash", "drive_file_id" => file_id, "user_id" => user_id}
      }) do
    Logger.info("UpstreamSyncWorker: Trashing file #{file_id} for user #{user_id}")
    # TODO: Implement Drive API call to trash the remote file
    # Ex: Assistant.Integrations.Google.Drive.trash_file(token, file_id)
    :ok
  end

  def perform(%Oban.Job{
        args:
          %{
            "action" => "write_intent",
            "user_id" => user_id,
            "drive_file_id" => file_id,
            "intent_id" => intent_id
          } = args
      }) do
    Logger.info("UpstreamSyncWorker: Processing write intent",
      user_id: user_id,
      drive_file_id: file_id,
      intent_id: intent_id
    )

    if StateStore.write_intent_already_applied?(user_id, file_id, intent_id) do
      Logger.info("UpstreamSyncWorker: Skipping replayed write intent",
        user_id: user_id,
        drive_file_id: file_id,
        intent_id: intent_id
      )

      :ok
    else
      _ =
        StateStore.record_upstream_intent_event(user_id, file_id, intent_id, "attempt", %{
          "args" => Map.drop(args, ["action"])
        })

      case Repo.get_by(SyncedFile, user_id: user_id, drive_file_id: file_id) do
        nil ->
          _ =
            StateStore.record_upstream_intent_event(user_id, file_id, intent_id, "failure", %{
              "reason" => "synced_file_not_found"
            })

          :ok

        synced_file ->
          synced_file
          |> Ecto.Changeset.change(%{sync_status: "synced", last_synced_at: DateTime.utc_now()})
          |> Repo.update!()

          _ = StateStore.record_upstream_intent_event(user_id, file_id, intent_id, "success", %{})
          :ok
      end
    end
  end

  def perform(%Oban.Job{args: %{"synced_file_id" => id}}) do
    Logger.info("UpstreamSyncWorker: Processing synced_file_id #{id}")

    case Repo.get(SyncedFile, id) do
      nil ->
        Logger.warning("UpstreamSyncWorker: SyncedFile #{id} not found, dropping job.")
        :ok

      %SyncedFile{sync_status: "local_ahead"} = synced_file ->
        push_updates_to_drive(synced_file)

      synced_file ->
        Logger.info(
          "UpstreamSyncWorker: SyncedFile #{id} is not local_ahead (status: #{synced_file.sync_status}). Skipping."
        )

        :ok
    end
  end

  defp push_updates_to_drive(synced_file) do
    # Here we would:
    # 1. Fetch the user's active Google Token.
    # 2. Convert markdown/csv string back into Google Docs/Sheets format if applicable.
    # 3. Use Assistant.Integrations.Google.Drive.update_file(token, file_id, content) 
    #    OR Drive.create_file if it's a new "local:xyz" file.
    # 4. Update the synced_file back to "synced", update remote_checksum.

    # We will raise an error if token fails so Oban retries it.

    Logger.info(
      "UpstreamSyncWorker Placeholder: Successfully handled upstream sync for #{synced_file.id}"
    )

    # Simulate success for the Phase 1 build
    synced_file
    |> Ecto.Changeset.change(%{sync_status: "synced", last_synced_at: DateTime.utc_now()})
    |> Repo.update!()

    :ok
  end
end
