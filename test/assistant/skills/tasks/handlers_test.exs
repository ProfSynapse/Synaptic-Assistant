# test/assistant/skills/tasks/handlers_test.exs — Tests for task skill handlers.
#
# Verifies all 5 task handler modules compile, implement the Handler behaviour,
# and handle missing required parameters and not-found cases correctly.
# Uses real DB via DataCase for the Queries layer.

defmodule Assistant.Skills.Tasks.HandlersTest do
  use Assistant.DataCase, async: true

  alias Assistant.Skills.Context
  alias Assistant.Skills.Tasks.{Create, Search, Get, Update, Delete}
  alias Assistant.Skills.Result
  alias Assistant.TaskManager.Queries

  @handlers [Create, Search, Get, Update, Delete]

  defp build_context do
    %Context{
      conversation_id: Ecto.UUID.generate(),
      execution_id: Ecto.UUID.generate(),
      user_id: Ecto.UUID.generate()
    }
  end

  # ---------------------------------------------------------------
  # Module compilation and behaviour
  # ---------------------------------------------------------------

  describe "module compilation and behaviour" do
    test "all handler modules are loaded" do
      for handler <- @handlers do
        assert Code.ensure_loaded?(handler),
               "#{inspect(handler)} should be loaded"
      end
    end

    test "all handlers export execute/2" do
      for handler <- @handlers do
        assert function_exported?(handler, :execute, 2),
               "#{inspect(handler)} should export execute/2"
      end
    end
  end

  # ---------------------------------------------------------------
  # Create handler
  # ---------------------------------------------------------------

  describe "Create handler" do
    test "returns error for missing --title flag" do
      ctx = build_context()
      assert {:ok, %Result{status: :error, content: content}} = Create.execute(%{}, ctx)
      assert content =~ "Missing required flag: --title"
    end

    test "creates task with valid title" do
      ctx = build_context()

      assert {:ok, %Result{status: :ok, side_effects: [:task_created]} = result} =
               Create.execute(%{"title" => "Test task from handler"}, ctx)

      assert result.content =~ "Task created successfully"
      assert result.metadata[:task_id] != nil
      assert result.metadata[:short_id] != nil
    end

    test "creates task with all optional flags" do
      ctx = build_context()

      flags = %{
        "title" => "Full task",
        "description" => "A detailed description",
        "priority" => "high",
        "tags" => "bug,urgent"
      }

      assert {:ok, %Result{status: :ok, content: content}} = Create.execute(flags, ctx)
      assert content =~ "Full task"
    end

    test "handles invalid due date gracefully" do
      ctx = build_context()

      flags = %{
        "title" => "Task with bad date",
        "due" => "not-a-date"
      }

      # parse_date returns nil for invalid dates, so task is created without due_date
      assert {:ok, %Result{status: :ok}} = Create.execute(flags, ctx)
    end
  end

  # ---------------------------------------------------------------
  # Search handler
  # ---------------------------------------------------------------

  describe "Search handler" do
    test "returns empty results for no matching tasks" do
      ctx = build_context()

      assert {:ok, %Result{status: :ok, content: content}} =
               Search.execute(%{}, ctx)

      # Either finds tasks or says "No tasks found"
      assert is_binary(content)
    end

    test "finds tasks by status filter" do
      ctx = build_context()

      # Create a task first
      {:ok, _task} = Queries.create_task(%{title: "Searchable task", status: "todo"})

      assert {:ok, %Result{status: :ok, metadata: %{count: count}}} =
               Search.execute(%{"status" => "todo"}, ctx)

      assert count >= 1
    end

    test "returns metadata with count" do
      ctx = build_context()

      assert {:ok, %Result{status: :ok, metadata: metadata}} =
               Search.execute(%{}, ctx)

      assert Map.has_key?(metadata, :count)
    end
  end

  # ---------------------------------------------------------------
  # Get handler
  # ---------------------------------------------------------------

  describe "Get handler" do
    test "returns error for missing task ID" do
      ctx = build_context()

      assert {:ok, %Result{status: :error, content: content}} = Get.execute(%{}, ctx)
      assert content =~ "Missing required argument"
    end

    test "returns error for non-existent task" do
      ctx = build_context()
      fake_id = Ecto.UUID.generate()

      assert {:ok, %Result{status: :error, content: content}} =
               Get.execute(%{"id" => fake_id}, ctx)

      assert content =~ "Task not found"
    end

    test "returns task details for valid UUID" do
      ctx = build_context()
      {:ok, task} = Queries.create_task(%{title: "Gettable task"})

      assert {:ok, %Result{status: :ok, content: content, metadata: metadata}} =
               Get.execute(%{"id" => task.id}, ctx)

      assert content =~ "Gettable task"
      assert metadata[:task_id] == task.id
      assert metadata[:short_id] == task.short_id
    end

    test "accepts short_id via _positional flag" do
      ctx = build_context()
      {:ok, task} = Queries.create_task(%{title: "Positional task"})

      assert {:ok, %Result{status: :ok, content: content}} =
               Get.execute(%{"_positional" => task.short_id}, ctx)

      assert content =~ "Positional task"
    end
  end

  # ---------------------------------------------------------------
  # Update handler
  # ---------------------------------------------------------------

  describe "Update handler" do
    test "returns error for missing task ID" do
      ctx = build_context()

      assert {:ok, %Result{status: :error, content: content}} = Update.execute(%{}, ctx)
      assert content =~ "Missing required argument: task ID"
    end

    test "returns error for non-existent task" do
      ctx = build_context()
      fake_id = Ecto.UUID.generate()

      assert {:ok, %Result{status: :error, content: content}} =
               Update.execute(%{"id" => fake_id, "status" => "in_progress"}, ctx)

      assert content =~ "Task not found"
    end

    test "returns error when no fields to update" do
      ctx = build_context()
      {:ok, task} = Queries.create_task(%{title: "No-change task"})

      assert {:ok, %Result{status: :error, content: content}} =
               Update.execute(%{"id" => task.id}, ctx)

      assert content =~ "No fields to update"
    end

    test "updates task status successfully" do
      ctx = build_context()
      {:ok, task} = Queries.create_task(%{title: "Updatable task"})

      assert {:ok, %Result{status: :ok, side_effects: [:task_updated]} = result} =
               Update.execute(%{"id" => task.id, "status" => "in_progress"}, ctx)

      assert result.content =~ task.short_id
      assert result.content =~ "updated"
    end
  end

  # ---------------------------------------------------------------
  # Delete handler
  # ---------------------------------------------------------------

  describe "Delete handler" do
    test "returns error for missing task ID" do
      ctx = build_context()

      assert {:ok, %Result{status: :error, content: content}} = Delete.execute(%{}, ctx)
      assert content =~ "Missing required argument: task ID"
    end

    test "returns error for non-existent task" do
      ctx = build_context()
      fake_id = Ecto.UUID.generate()

      assert {:ok, %Result{status: :error, content: content}} =
               Delete.execute(%{"id" => fake_id}, ctx)

      assert content =~ "Task not found"
    end

    test "soft-deletes (archives) a task" do
      ctx = build_context()
      {:ok, task} = Queries.create_task(%{title: "Deletable task"})

      assert {:ok, %Result{status: :ok, side_effects: [:task_archived]} = result} =
               Delete.execute(%{"id" => task.id}, ctx)

      assert result.content =~ task.short_id
      assert result.content =~ "archived"
      assert result.metadata[:task_id] == task.id
    end

    test "uses custom reason when provided" do
      ctx = build_context()
      {:ok, task} = Queries.create_task(%{title: "Custom reason task"})

      assert {:ok, %Result{status: :ok, content: content}} =
               Delete.execute(%{"id" => task.id, "reason" => "superseded"}, ctx)

      assert content =~ "superseded"
    end
  end
end
