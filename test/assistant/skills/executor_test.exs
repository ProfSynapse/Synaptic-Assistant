# test/assistant/skills/executor_test.exs
#
# Tests for the Task.Supervisor-based skill executor.
# Verifies success, error, timeout, and crash handling.

defmodule Assistant.Skills.ExecutorTest do
  use ExUnit.Case, async: true

  alias Assistant.Skills.{Context, Executor, Result}

  setup do
    # Ensure TaskSupervisor is running
    case Task.Supervisor.start_link(name: Assistant.Skills.TaskSupervisor) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    context = %Context{
      conversation_id: "test-conv-#{System.unique_integer([:positive])}",
      execution_id: "test-exec-#{System.unique_integer([:positive])}",
      user_id: "test-user"
    }

    %{context: context}
  end

  # ---------------------------------------------------------------
  # Successful execution
  # ---------------------------------------------------------------

  describe "execute/4 — success" do
    test "returns {:ok, result} when handler succeeds", %{context: context} do
      handler =
        build_handler(fn _flags, _ctx ->
          {:ok, %Result{status: :ok, content: "Skill completed successfully"}}
        end)

      assert {:ok, %Result{status: :ok, content: "Skill completed successfully"}} =
               Executor.execute(handler, %{}, context)
    end

    test "passes flags and context to handler", %{context: context} do
      test_pid = self()

      handler =
        build_handler(fn flags, ctx ->
          send(test_pid, {:handler_called, flags, ctx})
          {:ok, %Result{status: :ok, content: "ok"}}
        end)

      flags = %{"key" => "value"}
      Executor.execute(handler, flags, context)

      assert_receive {:handler_called, ^flags, ^context}
    end
  end

  # ---------------------------------------------------------------
  # Error handling
  # ---------------------------------------------------------------

  describe "execute/4 — error" do
    test "returns {:error, reason} when handler returns error", %{context: context} do
      handler =
        build_handler(fn _flags, _ctx ->
          {:error, :validation_failed}
        end)

      assert {:error, :validation_failed} =
               Executor.execute(handler, %{}, context)
    end
  end

  # ---------------------------------------------------------------
  # Crash handling
  # ---------------------------------------------------------------

  describe "execute/4 — crash" do
    test "returns {:error, {:skill_crash, reason}} when handler crashes", %{context: context} do
      handler =
        build_handler(fn _flags, _ctx ->
          raise "handler crash"
        end)

      assert {:error, {:skill_crash, _reason}} =
               Executor.execute(handler, %{}, context)
    end
  end

  # ---------------------------------------------------------------
  # Timeout handling
  # ---------------------------------------------------------------

  describe "execute/4 — timeout" do
    test "returns {:error, :timeout} when handler exceeds timeout", %{context: context} do
      handler =
        build_handler(fn _flags, _ctx ->
          Process.sleep(5_000)
          {:ok, %Result{status: :ok, content: "too late"}}
        end)

      assert {:error, :timeout} =
               Executor.execute(handler, %{}, context, timeout: 50)
    end
  end

  # ---------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------

  # Creates an anonymous module that implements the handler interface.
  # Uses a named ETS table to store the callback since anonymous closures
  # and ETS references cannot be unquoted into module AST.
  defp build_handler(execute_fn) do
    table_name = :"handler_fn_#{System.unique_integer([:positive])}"
    :ets.new(table_name, [:named_table, :set, :public])
    :ets.insert(table_name, {:fn, execute_fn})

    module_name = :"TestHandler_#{System.unique_integer([:positive])}"

    Module.create(
      module_name,
      quote do
        def execute(flags, context) do
          [{:fn, fun}] = :ets.lookup(unquote(table_name), :fn)
          fun.(flags, context)
        end
      end,
      Macro.Env.location(__ENV__)
    )

    module_name
  end
end
