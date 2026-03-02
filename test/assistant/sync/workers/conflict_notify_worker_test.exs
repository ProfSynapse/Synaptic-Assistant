# test/assistant/sync/workers/conflict_notify_worker_test.exs
#
# Tests for Assistant.Sync.Workers.ConflictNotifyWorker — Oban worker that
# logs conflict notifications. Verifies correct handling of valid and invalid
# args, and graceful handling of missing synced files.
#
# Related files:
#   - lib/assistant/sync/workers/conflict_notify_worker.ex (module under test)
#   - lib/assistant/sync/state_store.ex (loads synced file records)

defmodule Assistant.Sync.Workers.ConflictNotifyWorkerTest do
  use Assistant.DataCase, async: true

  alias Assistant.Sync.StateStore
  alias Assistant.Sync.Workers.ConflictNotifyWorker

  # ---------------------------------------------------------------
  # Setup
  # ---------------------------------------------------------------

  setup do
    user = insert_test_user("conflict-notify")
    %{user: user}
  end

  defp insert_test_user(prefix) do
    %Assistant.Schemas.User{}
    |> Assistant.Schemas.User.changeset(%{
      external_id: "#{prefix}-#{System.unique_integer([:positive])}",
      channel: "test"
    })
    |> Repo.insert!()
  end

  # ---------------------------------------------------------------
  # perform/1
  # ---------------------------------------------------------------

  describe "perform/1" do
    test "logs notification for existing synced file", %{user: user} do
      {:ok, file} =
        StateStore.create_synced_file(%{
          user_id: user.id,
          drive_file_id: "conflict-file-001",
          drive_file_name: "conflicted.md",
          drive_mime_type: "text/plain",
          local_path: "conflicted.md",
          local_format: "md",
          sync_status: "conflict",
          sync_error: "Both sides modified"
        })

      job = %Oban.Job{
        args: %{"synced_file_id" => file.id, "user_id" => user.id}
      }

      assert :ok = ConflictNotifyWorker.perform(job)
    end

    test "returns :ok when synced file no longer exists", %{user: user} do
      job = %Oban.Job{
        args: %{
          "synced_file_id" => Ecto.UUID.generate(),
          "user_id" => user.id
        }
      }

      # Should not crash — just log and return :ok
      assert :ok = ConflictNotifyWorker.perform(job)
    end

    test "returns :ok for invalid args" do
      job = %Oban.Job{args: %{"unexpected" => "args"}}
      assert :ok = ConflictNotifyWorker.perform(job)
    end
  end

  # ---------------------------------------------------------------
  # Worker configuration
  # ---------------------------------------------------------------

  describe "worker configuration" do
    test "uses :sync queue" do
      assert ConflictNotifyWorker.__opts__()[:queue] == :sync
    end

    test "has max_attempts of 3" do
      assert ConflictNotifyWorker.__opts__()[:max_attempts] == 3
    end
  end
end
