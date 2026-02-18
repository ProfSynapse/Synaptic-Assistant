# test/assistant/scheduler/workers/compaction_worker_test.exs — Smoke tests for CompactionWorker.
#
# Verifies the module compiles and is a valid Oban worker.
# Full integration tests (with Oban sandbox) are deferred to the TEST phase.

defmodule Assistant.Scheduler.Workers.CompactionWorkerTest do
  use ExUnit.Case, async: true

  alias Assistant.Scheduler.Workers.CompactionWorker

  describe "module compilation" do
    test "module is loaded and is an Oban worker" do
      assert function_exported?(CompactionWorker, :perform, 1)
      assert function_exported?(CompactionWorker, :new, 1)
      assert function_exported?(CompactionWorker, :new, 2)
    end

    test "new/1 builds a valid Oban job changeset" do
      changeset = CompactionWorker.new(%{conversation_id: "test-conv-id"})
      assert %Ecto.Changeset{} = changeset
      assert changeset.valid?
    end

    test "job uses compaction queue with max 3 attempts" do
      changeset = CompactionWorker.new(%{conversation_id: "test-conv-id"})
      changes = changeset.changes

      assert changes[:queue] == "compaction"
      assert changes[:max_attempts] == 3
    end
  end
end
