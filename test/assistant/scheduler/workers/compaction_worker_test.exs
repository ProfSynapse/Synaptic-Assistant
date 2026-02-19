# test/assistant/scheduler/workers/compaction_worker_test.exs — Tests for CompactionWorker.
#
# Uses Code.ensure_loaded? for Oban module checks instead of function_exported?,
# which avoids issues when the full Oban application isn't started.
# Tests the worker's changeset creation and queue configuration.

defmodule Assistant.Scheduler.Workers.CompactionWorkerTest do
  use ExUnit.Case, async: true

  alias Assistant.Scheduler.Workers.CompactionWorker

  describe "module compilation" do
    test "module is loaded and defines Oban.Worker callbacks" do
      assert Code.ensure_loaded?(CompactionWorker)
      assert function_exported?(CompactionWorker, :perform, 1)
      assert function_exported?(CompactionWorker, :new, 1)
      assert function_exported?(CompactionWorker, :new, 2)
    end
  end

  describe "new/1 changeset" do
    test "builds a valid Oban job changeset" do
      changeset = CompactionWorker.new(%{conversation_id: "test-conv-id"})
      assert %Ecto.Changeset{} = changeset
      assert changeset.valid?
    end

    test "changeset includes the conversation_id in args" do
      changeset = CompactionWorker.new(%{conversation_id: "conv-123"})
      assert changeset.changes[:args] == %{conversation_id: "conv-123"}
    end

    test "job uses compaction queue with max 3 attempts" do
      changeset = CompactionWorker.new(%{conversation_id: "test-conv-id"})
      changes = changeset.changes

      assert changes[:queue] == "compaction"
      assert changes[:max_attempts] == 3
    end

    test "includes uniqueness configuration" do
      changeset = CompactionWorker.new(%{conversation_id: "test-conv-id"})
      changes = changeset.changes

      # Oban unique key is set via the worker module options
      assert changes[:unique] != nil
    end
  end

  describe "new/1 with optional params" do
    test "accepts token_budget in args" do
      changeset =
        CompactionWorker.new(%{
          conversation_id: "conv-123",
          token_budget: 4096
        })

      assert changeset.valid?
      assert changeset.changes[:args][:token_budget] == 4096
    end

    test "accepts message_limit in args" do
      changeset =
        CompactionWorker.new(%{
          conversation_id: "conv-123",
          message_limit: 50
        })

      assert changeset.valid?
      assert changeset.changes[:args][:message_limit] == 50
    end
  end
end
