# test/assistant/task_manager/queries_test.exs — Smoke tests for TaskManager.Queries.

defmodule Assistant.TaskManager.QueriesTest do
  use Assistant.DataCase, async: true

  alias Assistant.TaskManager.Queries
  alias Assistant.Schemas.User

  defp create_test_user do
    %User{}
    |> User.changeset(%{
      external_id: "test-user-#{System.unique_integer([:positive])}",
      channel: "test"
    })
    |> Repo.insert!()
  end

  setup do
    user = create_test_user()
    %{user: user}
  end

  describe "module compilation" do
    test "module is loaded and has expected functions" do
      assert Code.ensure_loaded?(Queries)
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
    test "creates a task with auto-generated short_id and retrieves it", %{user: user} do
      attrs = %{creator_id: user.id, title: "Test smoke task", description: "A smoke test task", priority: "high"}
      assert {:ok, task} = Queries.create_task(attrs)
      assert task.title == "Test smoke task"
      assert task.priority == "high"
      assert task.status == "todo"
      assert String.starts_with?(task.short_id, "T-")
      # Description is virtual — preserved in the returned struct (not persisted to DB)
      assert task.description == "A smoke test task"

      assert {:ok, fetched} = Queries.get_task(task.id)
      assert fetched.id == task.id
      assert fetched.title == "Test smoke task"
      # get_task hydrates encrypted fields — description round-trips through encrypt/decrypt
      assert fetched.description == "A smoke test task"

      assert {:ok, fetched_by_short} = Queries.get_task(task.short_id)
      assert fetched_by_short.id == task.id
    end

    test "returns error for missing title", %{user: user} do
      assert {:error, changeset} = Queries.create_task(%{creator_id: user.id, description: "no title"})
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
    test "generates incrementing short_ids", %{user: user} do
      {:ok, t1} = Queries.create_task(%{creator_id: user.id, title: "First task"})
      {:ok, t2} = Queries.create_task(%{creator_id: user.id, title: "Second task"})

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
