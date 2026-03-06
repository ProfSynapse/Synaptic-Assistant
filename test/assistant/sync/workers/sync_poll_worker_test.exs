# test/assistant/sync/workers/sync_poll_worker_test.exs
#
# Tests for Assistant.Sync.Workers.SyncPollWorker — Oban cron worker that
# polls the Drive Changes API. Tests verify the worker's interaction with
# StateStore (DB) and its error resilience. Since we cannot mock the external
# APIs (no Bypass/Mox for Drive), we test the DB-level behavior: cursor
# management, scope filtering, and that the worker handles auth failures
# gracefully.
#
# Related files:
#   - lib/assistant/sync/workers/sync_poll_worker.ex (module under test)
#   - lib/assistant/sync/state_store.ex (DB state)
#   - lib/assistant/integrations/google/auth.ex (token provider)

defmodule Assistant.Sync.Workers.SyncPollWorkerTest do
  use Assistant.DataCase, async: false

  alias Assistant.Sync.StateStore
  alias Assistant.Sync.Workers.SyncPollWorker

  # ---------------------------------------------------------------
  # Setup
  # ---------------------------------------------------------------

  setup do
    user = insert_test_user("poll-worker")
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
  # perform/1 — basic flow
  # ---------------------------------------------------------------

  describe "perform/1" do
    test "returns :ok when no users have cursors" do
      # No cursors = no work = success
      assert :ok = SyncPollWorker.perform(%Oban.Job{args: %{}})
    end

    test "returns :ok even when auth fails for a user", %{user: user} do
      # Create a cursor for the user — poll will try to auth and fail
      # (no OAuth token configured for test user), but should not crash
      {:ok, _} =
        StateStore.upsert_cursor(%{
          user_id: user.id,
          drive_id: nil,
          start_page_token: "test-token-123"
        })

      # Should complete without error — auth failure is logged, not raised
      assert :ok = SyncPollWorker.perform(%Oban.Job{args: %{}})
    end

    test "processes multiple users independently", %{user: user} do
      user2 = insert_test_user("poll-worker-2")

      {:ok, _} =
        StateStore.upsert_cursor(%{user_id: user.id, drive_id: nil, start_page_token: "t1"})

      {:ok, _} =
        StateStore.upsert_cursor(%{user_id: user2.id, drive_id: nil, start_page_token: "t2"})

      # Both users have cursors — both will fail auth but worker should not crash
      assert :ok = SyncPollWorker.perform(%Oban.Job{args: %{}})
    end
  end

  # ---------------------------------------------------------------
  # perform/1 — per-user job path
  # ---------------------------------------------------------------

  describe "perform/1 per-user dispatch" do
    test "per-user job returns :ok even with auth failure", %{user: user} do
      {:ok, _} =
        StateStore.upsert_cursor(%{
          user_id: user.id,
          drive_id: nil,
          start_page_token: "per-user-token"
        })

      # Direct per-user job — auth will fail but should not crash
      assert :ok = SyncPollWorker.perform(%Oban.Job{args: %{"user_id" => user.id}})
    end
  end

  # ---------------------------------------------------------------
  # Scope filtering (DB-level verification)
  # ---------------------------------------------------------------

  describe "scope filtering setup" do
    test "files outside sync scopes would be skipped", %{user: user} do
      # Create a cursor but no scope — any changes found would be filtered out
      {:ok, _} =
        StateStore.upsert_cursor(%{
          user_id: user.id,
          drive_id: nil,
          start_page_token: "scope-test-token"
        })

      # Verify no scopes exist
      assert [] = StateStore.list_scopes(user.id)

      # folder_in_scope? returns nil for any folder
      assert nil == StateStore.folder_in_scope?(user.id, nil, "any-folder")
    end

    test "files within sync scopes would be processed", %{user: user} do
      {:ok, _} =
        StateStore.upsert_scope(%{
          user_id: user.id,
          drive_id: nil,
          folder_id: "folder-123",
          folder_name: "Projects"
        })

      assert StateStore.folder_in_scope?(user.id, nil, "folder-123") != nil
    end

    test "exact file scopes are treated as in scope", %{user: user} do
      {:ok, _} =
        StateStore.upsert_scope(%{
          user_id: user.id,
          drive_id: nil,
          folder_id: "folder-123",
          folder_name: "Projects",
          file_id: "file-123",
          file_name: "Roadmap",
          file_mime_type: "application/pdf"
        })

      assert StateStore.file_in_scope?(user.id, nil, "folder-123", "file-123") != nil
    end
  end

  # ---------------------------------------------------------------
  # Oban worker configuration
  # ---------------------------------------------------------------

  describe "worker configuration" do
    test "uses :sync queue" do
      assert SyncPollWorker.__opts__()[:queue] == :sync
    end

    test "has max_attempts of 3" do
      assert SyncPollWorker.__opts__()[:max_attempts] == 3
    end
  end
end
