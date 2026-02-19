# test/assistant/skills/workflow/cancel_test.exs
#
# Tests for the workflow.cancel skill handler. Uses a temporary directory
# for workflow files and stubs Scheduler/QuantumLoader interactions.
# Tests name validation, file deletion, and error handling.

defmodule Assistant.Skills.Workflow.CancelTest do
  use ExUnit.Case, async: false

  alias Assistant.Skills.Workflow.Cancel
  alias Assistant.Skills.Context

  # ---------------------------------------------------------------
  # Setup — temp directory with a pre-existing workflow file
  # Start Scheduler + QuantumLoader since Cancel calls QuantumLoader.cancel/1
  # ---------------------------------------------------------------

  setup do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "workflow_cancel_test_#{:erlang.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp_dir)
    Application.put_env(:assistant, :workflows_dir, tmp_dir)

    # Ensure Quantum Scheduler is running (QuantumLoader depends on it)
    case Process.whereis(Assistant.Scheduler) do
      nil -> {:ok, _} = Assistant.Scheduler.start_link()
      _pid -> :ok
    end

    # Create a workflow file to cancel
    workflow_path = Path.join(tmp_dir, "test-workflow.md")

    File.write!(workflow_path, """
    ---
    name: "test-workflow"
    description: "A test workflow"
    cron: "0 8 * * *"
    ---
    Run daily task.
    """)

    # Start QuantumLoader so it registers the cron job for test-workflow
    case Process.whereis(Assistant.Scheduler.QuantumLoader) do
      nil -> {:ok, _} = Assistant.Scheduler.QuantumLoader.start_link()
      _pid -> Assistant.Scheduler.QuantumLoader.reload()
    end

    on_exit(fn ->
      Application.delete_env(:assistant, :workflows_dir)
      File.rm_rf!(tmp_dir)

      safe_stop(Assistant.Scheduler.QuantumLoader)
      safe_stop(Assistant.Scheduler)
    end)

    %{workflows_dir: tmp_dir, workflow_path: workflow_path}
  end

  defp build_context do
    %Context{
      conversation_id: "conv-1",
      execution_id: "exec-1",
      user_id: "user-1",
      integrations: %{}
    }
  end

  defp safe_stop(name) do
    case Process.whereis(name) do
      nil -> :ok
      pid ->
        try do
          GenServer.stop(pid, :normal, 5_000)
        catch
          :exit, _ -> :ok
        end
    end
  end

  # ---------------------------------------------------------------
  # Happy path — cancel without delete
  # ---------------------------------------------------------------

  describe "execute/2 cancel without delete" do
    test "cancels workflow and preserves file", %{workflow_path: path} do
      {:ok, result} = Cancel.execute(%{"name" => "test-workflow"}, build_context())

      assert result.status == :ok
      assert result.content =~ "cron job removed"
      assert result.content =~ "File preserved"
      assert result.side_effects == [:workflow_canceled]
      assert result.metadata.workflow_name == "test-workflow"
      assert result.metadata.file_deleted == false

      # File still exists
      assert File.exists?(path)
    end
  end

  # ---------------------------------------------------------------
  # Cancel with --delete
  # ---------------------------------------------------------------

  describe "execute/2 cancel with --delete" do
    test "cancels workflow and deletes file", %{workflow_path: path} do
      {:ok, result} =
        Cancel.execute(%{"name" => "test-workflow", "delete" => "true"}, build_context())

      assert result.status == :ok
      assert result.content =~ "canceled and file deleted"
      assert result.metadata.file_deleted == true

      # File should be removed
      refute File.exists?(path)
    end

    test "--delete=false preserves file", %{workflow_path: path} do
      {:ok, result} =
        Cancel.execute(%{"name" => "test-workflow", "delete" => "false"}, build_context())

      assert result.status == :ok
      assert result.content =~ "File preserved"
      assert File.exists?(path)
    end
  end

  # ---------------------------------------------------------------
  # Missing name
  # ---------------------------------------------------------------

  describe "execute/2 missing name" do
    test "returns error when --name is missing" do
      {:ok, result} = Cancel.execute(%{}, build_context())

      assert result.status == :error
      assert result.content =~ "--name"
    end
  end

  # ---------------------------------------------------------------
  # Workflow not found
  # ---------------------------------------------------------------

  describe "execute/2 workflow not found" do
    test "returns error for non-existent workflow" do
      {:ok, result} = Cancel.execute(%{"name" => "nonexistent"}, build_context())

      assert result.status == :error
      assert result.content =~ "not found"
    end
  end
end
