# test/assistant/task_manager/queries_test.exs — Smoke tests for TaskManager.Queries.
#
# Verifies the module compiles and the create_task/get_task round-trip works
# against the real database via Ecto sandbox.
#
# Comprehensive unit tests are deferred to the TEST phase.

defmodule Assistant.TaskManager.QueriesTest do
  use Assistant.DataCase, async: true

  alias Assistant.TaskManager.Queries

  describe "module compilation" do
    test "module is loaded and has expected functions" do
      assert function_exported?(Queries, :create_task, 1)
      assert function_exported?(Queries, :get_task, 1)
      assert function_exported?(Queries, :update_task, 2)
      assert function_exported?(Queries, :delete_task, 1)
      assert function_exported?(Queries, :search_tasks, 1)
      assert function_exported?(Queries, :list_tasks, 1)
      assert function_exported?(Queries, :add_dependency, 2)
      assert function_exported?(Queries, :remove_dependency, 2)
      assert function_exported?(Queries, :add_comment, 2)
      assert function_exported?(Queries, :list_comments, 1)
      assert function_exported?(Queries, :get_history, 1)
      assert function_exported?(Queries, :check_blocked_status, 1)
      assert function_exported?(Queries, :generate_short_id, 0)
    end
  end

  describe "create_task/1 and get_task/1 round-trip" do
    test "creates a task with auto-generated short_id and retrieves it" do
      attrs = %{title: "Test smoke task", description: "A smoke test task", priority: "high"}

      assert {:ok, task} = Queries.create_task(attrs)
      assert task.title == "Test smoke task"
      assert task.description == "A smoke test task"
      assert task.priority == "high"
      assert task.status == "todo"
      assert String.starts_with?(task.short_id, "T-")

      # Fetch by UUID
      assert {:ok, fetched} = Queries.get_task(task.id)
      assert fetched.id == task.id
      assert fetched.title == "Test smoke task"

      # Fetch by short_id
      assert {:ok, fetched_by_short} = Queries.get_task(task.short_id)
      assert fetched_by_short.id == task.id
    end

    test "returns error for missing title" do
      assert {:error, changeset} = Queries.create_task(%{description: "no title"})
      assert %{title: _} = errors_on(changeset)
    end

    test "get_task returns :not_found for nonexistent ID" do
      assert {:error, :not_found} = Queries.get_task("00000000-0000-0000-0000-000000000000")
    end

    test "get_task returns :not_found for nonexistent short_id" do
      assert {:error, :not_found} = Queries.get_task("T-999999")
    end
  end

  describe "short_id sequential generation" do
    test "generates incrementing short_ids" do
      {:ok, t1} = Queries.create_task(%{title: "First task"})
      {:ok, t2} = Queries.create_task(%{title: "Second task"})

      # Extract numeric suffix
      num1 = extract_short_id_number(t1.short_id)
      num2 = extract_short_id_number(t2.short_id)

      assert num2 == num1 + 1
    end
  end

  defp extract_short_id_number(short_id) do
    short_id
    |> String.replace(~r/^T-0*/, "")
    |> String.to_integer()
  end
end
