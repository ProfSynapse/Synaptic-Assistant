# test/assistant/scheduler/quantum_loader_test.exs
#
# Tests for the QuantumLoader GenServer. Starts a real Assistant.Scheduler
# (Quantum) process against a temp workflows directory to verify init,
# reload, and cancel workflows. Uses async: false because we start
# named processes (Assistant.Scheduler, QuantumLoader).

defmodule Assistant.Scheduler.QuantumLoaderTest do
  use ExUnit.Case, async: false

  alias Assistant.Scheduler.QuantumLoader

  # ---------------------------------------------------------------
  # Setup — temp directory + start Scheduler
  # ---------------------------------------------------------------

  setup do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "quantum_loader_test_#{:erlang.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp_dir)
    Application.put_env(:assistant, :workflows_dir, tmp_dir)

    # Ensure the Scheduler (Quantum) is running for add_job/delete_job
    case Process.whereis(Assistant.Scheduler) do
      nil -> {:ok, _} = Assistant.Scheduler.start_link()
      _pid -> :ok
    end

    on_exit(fn ->
      Application.delete_env(:assistant, :workflows_dir)
      File.rm_rf!(tmp_dir)

      safe_stop(QuantumLoader)
      safe_stop(Assistant.Scheduler)
    end)

    %{workflows_dir: tmp_dir}
  end

  defp write_workflow(dir, name, opts \\ []) do
    cron = Keyword.get(opts, :cron, nil)
    description = Keyword.get(opts, :description, "A test workflow")

    cron_line = if cron, do: ~s(cron: "#{cron}"\n), else: ""

    path = Path.join(dir, "#{name}.md")

    File.write!(path, """
    ---
    name: "#{name}"
    description: "#{description}"
    #{cron_line}---
    Run #{name} prompt.
    """)

    path
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

  defp stop_loader, do: safe_stop(QuantumLoader)

  # ---------------------------------------------------------------
  # Module compilation
  # ---------------------------------------------------------------

  describe "module compilation" do
    test "module is loaded and exports GenServer callbacks" do
      assert Code.ensure_loaded?(QuantumLoader)
      assert function_exported?(QuantumLoader, :start_link, 0)
      assert function_exported?(QuantumLoader, :start_link, 1)
      assert function_exported?(QuantumLoader, :reload, 0)
      assert function_exported?(QuantumLoader, :cancel, 1)
    end
  end

  # ---------------------------------------------------------------
  # init — empty directory
  # ---------------------------------------------------------------

  describe "init with empty directory" do
    test "starts with zero scheduled workflows", %{workflows_dir: _dir} do
      {:ok, pid} = QuantumLoader.start_link()
      assert Process.alive?(pid)

      state = :sys.get_state(pid)
      assert state.scheduled_count == 0
      assert state.job_refs == %{}

      stop_loader()
    end
  end

  # ---------------------------------------------------------------
  # init — with cron workflows
  # ---------------------------------------------------------------

  describe "init with cron workflows" do
    test "registers cron workflows on startup", %{workflows_dir: dir} do
      write_workflow(dir, "cron-daily", cron: "0 8 * * *")
      write_workflow(dir, "cron-hourly", cron: "0 * * * *")

      {:ok, _pid} = QuantumLoader.start_link()
      state = :sys.get_state(QuantumLoader)

      assert state.scheduled_count == 2
      assert Map.has_key?(state.job_refs, "cron-daily")
      assert Map.has_key?(state.job_refs, "cron-hourly")

      # Refs should be references (from make_ref)
      assert is_reference(state.job_refs["cron-daily"])
      assert is_reference(state.job_refs["cron-hourly"])

      stop_loader()
    end

    test "skips workflows without cron field", %{workflows_dir: dir} do
      write_workflow(dir, "no-cron")
      write_workflow(dir, "has-cron", cron: "0 9 * * 1")

      {:ok, _pid} = QuantumLoader.start_link()
      state = :sys.get_state(QuantumLoader)

      assert state.scheduled_count == 1
      assert Map.has_key?(state.job_refs, "has-cron")
      refute Map.has_key?(state.job_refs, "no-cron")

      stop_loader()
    end

    test "skips workflows with invalid cron expressions", %{workflows_dir: dir} do
      write_workflow(dir, "bad-cron", cron: "not-a-cron")
      write_workflow(dir, "good-cron", cron: "30 6 * * *")

      {:ok, _pid} = QuantumLoader.start_link()
      state = :sys.get_state(QuantumLoader)

      assert state.scheduled_count == 1
      assert Map.has_key?(state.job_refs, "good-cron")
      refute Map.has_key?(state.job_refs, "bad-cron")

      stop_loader()
    end
  end

  # ---------------------------------------------------------------
  # reload/0
  # ---------------------------------------------------------------

  describe "reload/0" do
    test "picks up new workflow files", %{workflows_dir: dir} do
      write_workflow(dir, "initial", cron: "0 8 * * *")

      {:ok, _pid} = QuantumLoader.start_link()
      state = :sys.get_state(QuantumLoader)
      assert state.scheduled_count == 1

      # Add a second workflow
      write_workflow(dir, "added-later", cron: "0 12 * * *")
      assert :ok = QuantumLoader.reload()

      state = :sys.get_state(QuantumLoader)
      assert state.scheduled_count == 2
      assert Map.has_key?(state.job_refs, "initial")
      assert Map.has_key?(state.job_refs, "added-later")

      stop_loader()
    end

    test "removes deleted workflow files on reload", %{workflows_dir: dir} do
      path = write_workflow(dir, "to-remove", cron: "0 8 * * *")

      {:ok, _pid} = QuantumLoader.start_link()
      state = :sys.get_state(QuantumLoader)
      assert state.scheduled_count == 1

      # Remove the file and reload
      File.rm!(path)
      assert :ok = QuantumLoader.reload()

      state = :sys.get_state(QuantumLoader)
      assert state.scheduled_count == 0
      assert state.job_refs == %{}

      stop_loader()
    end

    test "assigns fresh refs on reload", %{workflows_dir: dir} do
      write_workflow(dir, "persistent", cron: "0 8 * * *")

      {:ok, _pid} = QuantumLoader.start_link()
      state_before = :sys.get_state(QuantumLoader)
      old_ref = state_before.job_refs["persistent"]

      QuantumLoader.reload()

      state_after = :sys.get_state(QuantumLoader)
      new_ref = state_after.job_refs["persistent"]

      # make_ref() produces a new ref each time
      assert old_ref != new_ref

      stop_loader()
    end
  end

  # ---------------------------------------------------------------
  # cancel/1
  # ---------------------------------------------------------------

  describe "cancel/1" do
    test "removes a specific workflow job", %{workflows_dir: dir} do
      write_workflow(dir, "keep-me", cron: "0 8 * * *")
      write_workflow(dir, "cancel-me", cron: "0 12 * * *")

      {:ok, _pid} = QuantumLoader.start_link()
      state = :sys.get_state(QuantumLoader)
      assert state.scheduled_count == 2

      assert :ok = QuantumLoader.cancel("cancel-me")

      state = :sys.get_state(QuantumLoader)
      assert state.scheduled_count == 1
      assert Map.has_key?(state.job_refs, "keep-me")
      refute Map.has_key?(state.job_refs, "cancel-me")

      stop_loader()
    end

    test "is idempotent for non-existent workflow", %{workflows_dir: _dir} do
      {:ok, _pid} = QuantumLoader.start_link()

      # Cancel a workflow that was never scheduled
      assert :ok = QuantumLoader.cancel("nonexistent")

      state = :sys.get_state(QuantumLoader)
      assert state.scheduled_count == 0

      stop_loader()
    end
  end

  # ---------------------------------------------------------------
  # Missing workflows directory
  # ---------------------------------------------------------------

  describe "missing workflows directory" do
    test "starts with zero workflows when directory does not exist" do
      Application.put_env(:assistant, :workflows_dir, "/nonexistent/path/workflows")

      {:ok, _pid} = QuantumLoader.start_link()
      state = :sys.get_state(QuantumLoader)

      assert state.scheduled_count == 0
      assert state.job_refs == %{}

      stop_loader()
    end
  end
end
