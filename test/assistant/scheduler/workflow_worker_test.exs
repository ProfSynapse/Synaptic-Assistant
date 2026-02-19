# test/assistant/scheduler/workflow_worker_test.exs
#
# Tests for the WorkflowWorker Oban worker. Tests changeset creation,
# queue configuration, and perform/1 with temp workflow files.
# Follows the CompactionWorkerTest pattern for Oban worker testing.

defmodule Assistant.Scheduler.WorkflowWorkerTest do
  use ExUnit.Case, async: true

  alias Assistant.Scheduler.WorkflowWorker

  # ---------------------------------------------------------------
  # Module compilation
  # ---------------------------------------------------------------

  describe "module compilation" do
    test "module is loaded and defines Oban.Worker callbacks" do
      assert Code.ensure_loaded?(WorkflowWorker)
      assert function_exported?(WorkflowWorker, :perform, 1)
      assert function_exported?(WorkflowWorker, :new, 1)
      assert function_exported?(WorkflowWorker, :new, 2)
    end
  end

  # ---------------------------------------------------------------
  # new/1 changeset
  # ---------------------------------------------------------------

  describe "new/1 changeset" do
    test "builds a valid Oban job changeset" do
      changeset = WorkflowWorker.new(%{workflow_path: "priv/workflows/test.md"})
      assert %Ecto.Changeset{} = changeset
      assert changeset.valid?
    end

    test "changeset includes workflow_path in args" do
      changeset = WorkflowWorker.new(%{workflow_path: "priv/workflows/test.md"})
      assert changeset.changes[:args] == %{workflow_path: "priv/workflows/test.md"}
    end

    test "job uses scheduled queue with max 3 attempts" do
      changeset = WorkflowWorker.new(%{workflow_path: "priv/workflows/test.md"})
      changes = changeset.changes

      assert changes[:queue] == "scheduled"
      assert changes[:max_attempts] == 3
    end

    test "includes uniqueness configuration" do
      changeset = WorkflowWorker.new(%{workflow_path: "priv/workflows/test.md"})
      changes = changeset.changes

      assert changes[:unique] != nil
    end
  end

  # ---------------------------------------------------------------
  # perform/1 with valid workflow
  # ---------------------------------------------------------------

  describe "perform/1 with valid workflow" do
    setup do
      tmp_dir =
        Path.join(
          System.tmp_dir!(),
          "workflow_worker_test_#{:erlang.unique_integer([:positive])}"
        )

      File.mkdir_p!(tmp_dir)

      workflow_path = Path.join(tmp_dir, "test-workflow.md")

      File.write!(workflow_path, """
      ---
      name: "test-workflow"
      description: "A test workflow"
      ---
      Run this test prompt.
      """)

      on_exit(fn -> File.rm_rf!(tmp_dir) end)

      %{workflow_path: workflow_path}
    end

    test "returns :ok for valid workflow file", %{workflow_path: path} do
      job = %Oban.Job{args: %{"workflow_path" => path}}
      assert :ok = WorkflowWorker.perform(job)
    end
  end

  # ---------------------------------------------------------------
  # perform/1 error cases
  # ---------------------------------------------------------------

  describe "perform/1 error cases" do
    test "returns error for missing workflow file" do
      job = %Oban.Job{args: %{"workflow_path" => "/nonexistent/path/workflow.md"}}
      assert {:error, {:workflow_not_found, _}} = WorkflowWorker.perform(job)
    end

    test "returns error when workflow_path key is missing" do
      job = %Oban.Job{args: %{"some_other_key" => "value"}}
      assert {:error, :missing_workflow_path} = WorkflowWorker.perform(job)
    end

    test "returns error for empty args" do
      job = %Oban.Job{args: %{}}
      assert {:error, :missing_workflow_path} = WorkflowWorker.perform(job)
    end
  end

  # ---------------------------------------------------------------
  # perform/1 with channel (stubbed posting)
  # ---------------------------------------------------------------

  describe "perform/1 with channel" do
    setup do
      tmp_dir =
        Path.join(
          System.tmp_dir!(),
          "workflow_worker_channel_test_#{:erlang.unique_integer([:positive])}"
        )

      File.mkdir_p!(tmp_dir)

      workflow_path = Path.join(tmp_dir, "channel-workflow.md")

      File.write!(workflow_path, """
      ---
      name: "channel-workflow"
      description: "Workflow with channel"
      channel: "spaces/AAAABBBB"
      ---
      Generate a summary and post to channel.
      """)

      on_exit(fn -> File.rm_rf!(tmp_dir) end)

      %{workflow_path: workflow_path}
    end

    test "crashes when Goth registry is absent (channel posting not wrapped in try/catch)", %{
      workflow_path: path
    } do
      # BUG: maybe_post_to_channel/3 calls Chat.send_message which calls
      # Auth.token/0 -> Goth.fetch -> Registry.lookup. Without Goth started,
      # this raises ArgumentError (--no-start) or exits via GenServer.call
      # (full app). Either way, it's not handled gracefully.
      # The channel posting should be wrapped in try/catch for resilience.
      job = %Oban.Job{args: %{"workflow_path" => path}}

      crashed =
        try do
          WorkflowWorker.perform(job)
          false
        rescue
          ArgumentError -> true
        catch
          :exit, _ -> true
        end

      assert crashed, "Expected perform/1 to crash when Goth registry is absent"
    end
  end
end
