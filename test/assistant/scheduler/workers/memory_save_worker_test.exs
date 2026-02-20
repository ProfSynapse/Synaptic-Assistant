# test/assistant/scheduler/workers/memory_save_worker_test.exs — Tests for MemorySaveWorker.
#
# Tests the Oban worker configuration (changeset, queue, uniqueness) and
# perform/1 behavior (happy path, missing args, store errors, content formatting).
# Follows the same pattern as the sibling compaction_worker_test.exs.
#
# Related files:
#   - lib/assistant/scheduler/workers/memory_save_worker.ex (worker under test)
#   - lib/assistant/memory/store.ex (Memory.Store.create_memory_entry/1)
#   - test/assistant/scheduler/workers/compaction_worker_test.exs (sibling pattern)

defmodule Assistant.Scheduler.Workers.MemorySaveWorkerTest do
  use Assistant.DataCase, async: true

  alias Assistant.Scheduler.Workers.MemorySaveWorker

  # -------------------------------------------------------------------
  # Module compilation
  # -------------------------------------------------------------------

  describe "module compilation" do
    test "module is loaded and defines Oban.Worker callbacks" do
      assert Code.ensure_loaded?(MemorySaveWorker)
      assert function_exported?(MemorySaveWorker, :perform, 1)
      assert function_exported?(MemorySaveWorker, :new, 1)
      assert function_exported?(MemorySaveWorker, :new, 2)
    end
  end

  # -------------------------------------------------------------------
  # new/1 changeset
  # -------------------------------------------------------------------

  describe "new/1 changeset" do
    test "builds a valid Oban job changeset" do
      changeset = MemorySaveWorker.new(valid_args())
      assert %Ecto.Changeset{} = changeset
      assert changeset.valid?
    end

    test "changeset includes all args" do
      args = valid_args()
      changeset = MemorySaveWorker.new(args)
      assert changeset.changes[:args] == args
    end

    test "job uses memory queue with max 2 attempts" do
      changeset = MemorySaveWorker.new(valid_args())
      changes = changeset.changes

      assert changes[:queue] == "memory"
      assert changes[:max_attempts] == 2
    end

    test "does not use uniqueness constraint" do
      # Uniqueness was removed because agent_ids can be reused across turns
      # within the same conversation, risking silent deduplication of valid saves.
      changeset = MemorySaveWorker.new(valid_args())
      changes = changeset.changes

      assert changes[:unique] == nil
    end
  end

  # -------------------------------------------------------------------
  # perform/1 — missing required args
  # -------------------------------------------------------------------

  describe "perform/1 with missing required args" do
    test "cancels when user_id is nil" do
      args = valid_args() |> Map.delete(:user_id)
      job = build_job(args)

      assert {:cancel, :missing_required_args} = MemorySaveWorker.perform(job)
    end

    test "cancels when conversation_id is nil" do
      args = valid_args() |> Map.delete(:conversation_id)
      job = build_job(args)

      assert {:cancel, :missing_required_args} = MemorySaveWorker.perform(job)
    end

    test "cancels when agent_id is nil" do
      args = valid_args() |> Map.delete(:agent_id)
      job = build_job(args)

      assert {:cancel, :missing_required_args} = MemorySaveWorker.perform(job)
    end

    test "cancels when all three required fields are missing" do
      job = build_job(%{mission: "test", transcript: "text"})

      assert {:cancel, :missing_required_args} = MemorySaveWorker.perform(job)
    end
  end

  # -------------------------------------------------------------------
  # perform/1 — happy path (DB integration)
  # -------------------------------------------------------------------

  describe "perform/1 happy path" do
    setup do
      user = create_test_user()
      conversation = create_test_conversation(user.id)
      {:ok, user: user, conversation: conversation}
    end

    test "saves agent transcript to memory store", %{user: user, conversation: conv} do
      args =
        valid_args()
        |> Map.put(:user_id, user.id)
        |> Map.put(:conversation_id, conv.id)

      job = build_job(args)

      assert :ok = MemorySaveWorker.perform(job)

      # Verify entry was created in the database
      entries =
        Assistant.Schemas.MemoryEntry
        |> Ecto.Query.where([m], m.user_id == ^user.id)
        |> Ecto.Query.where([m], m.category == "agent_transcript")
        |> Repo.all()

      assert length(entries) == 1
      entry = hd(entries)
      assert entry.source_type == "agent_result"
      assert entry.source_conversation_id == conv.id
      assert entry.content =~ "Agent: test-agent-001"
      assert entry.content =~ "Status: completed"
      assert entry.content =~ "Mission: Summarize the document"
      assert entry.content =~ "Transcript:\nAgent completed the task."
      assert "agent:test-agent-001" in entry.tags
      assert "status:completed" in entry.tags
    end

    test "handles nil mission gracefully", %{user: user, conversation: conv} do
      args =
        valid_args()
        |> Map.put(:user_id, user.id)
        |> Map.put(:conversation_id, conv.id)
        |> Map.delete(:mission)

      job = build_job(args)

      assert :ok = MemorySaveWorker.perform(job)

      entry =
        Assistant.Schemas.MemoryEntry
        |> Ecto.Query.where([m], m.user_id == ^user.id)
        |> Repo.one!()

      # Nil mission should not add a mission section
      refute entry.content =~ "Mission:"
      assert entry.content =~ "Agent: test-agent-001"
    end

    test "handles empty string mission gracefully", %{user: user, conversation: conv} do
      args =
        valid_args()
        |> Map.put(:user_id, user.id)
        |> Map.put(:conversation_id, conv.id)
        |> Map.put(:mission, "")

      job = build_job(args)

      assert :ok = MemorySaveWorker.perform(job)

      entry =
        Assistant.Schemas.MemoryEntry
        |> Ecto.Query.where([m], m.user_id == ^user.id)
        |> Repo.one!()

      refute entry.content =~ "Mission:"
    end

    test "handles nil transcript", %{user: user, conversation: conv} do
      args =
        valid_args()
        |> Map.put(:user_id, user.id)
        |> Map.put(:conversation_id, conv.id)
        |> Map.delete(:transcript)

      job = build_job(args)

      assert :ok = MemorySaveWorker.perform(job)

      entry =
        Assistant.Schemas.MemoryEntry
        |> Ecto.Query.where([m], m.user_id == ^user.id)
        |> Repo.one!()

      assert entry.content =~ "(no transcript)"
    end

    test "handles empty string transcript", %{user: user, conversation: conv} do
      args =
        valid_args()
        |> Map.put(:user_id, user.id)
        |> Map.put(:conversation_id, conv.id)
        |> Map.put(:transcript, "")

      job = build_job(args)

      assert :ok = MemorySaveWorker.perform(job)

      entry =
        Assistant.Schemas.MemoryEntry
        |> Ecto.Query.where([m], m.user_id == ^user.id)
        |> Repo.one!()

      assert entry.content =~ "(empty transcript)"
    end

    test "defaults status to completed when not provided", %{user: user, conversation: conv} do
      args =
        valid_args()
        |> Map.put(:user_id, user.id)
        |> Map.put(:conversation_id, conv.id)
        |> Map.delete(:status)

      job = build_job(args)

      assert :ok = MemorySaveWorker.perform(job)

      entry =
        Assistant.Schemas.MemoryEntry
        |> Ecto.Query.where([m], m.user_id == ^user.id)
        |> Repo.one!()

      assert entry.content =~ "Status: completed"
      assert "status:completed" in entry.tags
    end

    test "saves with failed status when specified", %{user: user, conversation: conv} do
      args =
        valid_args()
        |> Map.put(:user_id, user.id)
        |> Map.put(:conversation_id, conv.id)
        |> Map.put(:status, "failed")

      job = build_job(args)

      assert :ok = MemorySaveWorker.perform(job)

      entry =
        Assistant.Schemas.MemoryEntry
        |> Ecto.Query.where([m], m.user_id == ^user.id)
        |> Repo.one!()

      assert entry.content =~ "Status: failed"
      assert "status:failed" in entry.tags
    end
  end

  # -------------------------------------------------------------------
  # perform/1 — store error returns :ok (no retry on validation errors)
  # -------------------------------------------------------------------

  describe "perform/1 with store errors" do
    test "returns :ok when store returns changeset error (no retry)" do
      # Use a user_id that doesn't exist in the DB — the foreign key
      # constraint will cause an insertion error.
      args =
        valid_args()
        |> Map.put(:user_id, Ecto.UUID.generate())
        |> Map.put(:conversation_id, Ecto.UUID.generate())

      job = build_job(args)

      # Should return :ok (not {:error, _}) so Oban doesn't retry
      assert :ok = MemorySaveWorker.perform(job)
    end
  end

  # -------------------------------------------------------------------
  # Helpers
  # -------------------------------------------------------------------

  defp valid_args do
    %{
      user_id: Ecto.UUID.generate(),
      conversation_id: Ecto.UUID.generate(),
      agent_id: "test-agent-001",
      mission: "Summarize the document",
      transcript: "Agent completed the task.",
      status: "completed"
    }
  end

  # Builds a fake %Oban.Job{} struct with string-keyed args (as Oban does
  # after JSON round-tripping through the database).
  defp build_job(args) do
    string_args =
      args
      |> Enum.map(fn {k, v} -> {to_string(k), v} end)
      |> Map.new()

    %Oban.Job{args: string_args}
  end

  defp create_test_user do
    %Assistant.Schemas.User{}
    |> Assistant.Schemas.User.changeset(%{
      external_id: "msw-test-#{System.unique_integer([:positive])}",
      channel: "test",
      display_name: "MemorySaveWorker Test User"
    })
    |> Repo.insert!()
  end

  defp create_test_conversation(user_id) do
    %Assistant.Schemas.Conversation{}
    |> Assistant.Schemas.Conversation.changeset(%{
      user_id: user_id,
      channel: "test",
      started_at: DateTime.utc_now()
    })
    |> Repo.insert!()
  end
end
