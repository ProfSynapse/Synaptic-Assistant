defmodule Assistant.Orchestrator.Tools.TaskToolsTest do
  use Assistant.DataCase, async: false

  alias Assistant.Orchestrator.Tools.{CreateTask, DeleteTask, GetTask, SearchTasks, UpdateTask}
  alias Assistant.Schemas.{Conversation, User}

  defp create_user_and_conversation do
    user =
      %User{}
      |> User.changeset(%{
        external_id: "task-tools-#{System.unique_integer([:positive])}",
        channel: "test"
      })
      |> Repo.insert!()

    {:ok, conversation} =
      %Conversation{}
      |> Conversation.changeset(%{channel: "test", user_id: user.id})
      |> Repo.insert()

    {user, conversation}
  end

  defp loop_state(user, conversation) do
    %{user_id: user.id, conversation_id: conversation.id, channel: "test"}
  end

  describe "orchestrator-native task tools" do
    test "create_task creates a task and get_task resolves by short ref" do
      {user, conversation} = create_user_and_conversation()
      state = loop_state(user, conversation)

      {:ok, create_result} =
        CreateTask.execute(
          %{
            "title" => "Review agent output",
            "description" => "Check the findings and decide next steps",
            "tags" => ["orchestrator", "review"]
          },
          state
        )

      assert create_result.status == :ok
      task_ref = create_result.metadata.task_ref

      {:ok, get_result} = GetTask.execute(%{"task_ref" => task_ref}, state)

      assert get_result.status == :ok
      assert get_result.content =~ "Review agent output"
      assert get_result.content =~ task_ref
    end

    test "search_tasks finds tasks for the current user" do
      {user, conversation} = create_user_and_conversation()
      state = loop_state(user, conversation)

      {:ok, _} = CreateTask.execute(%{"title" => "Searchable task"}, state)
      {:ok, search_result} = SearchTasks.execute(%{"query" => "Searchable"}, state)

      assert search_result.status == :ok
      assert search_result.content =~ "Searchable task"
    end

    test "update_task updates by short ref and merges tags" do
      {user, conversation} = create_user_and_conversation()
      state = loop_state(user, conversation)

      {:ok, create_result} =
        CreateTask.execute(%{"title" => "Needs update", "tags" => ["alpha"]}, state)

      task_ref = create_result.metadata.task_ref

      {:ok, update_result} =
        UpdateTask.execute(
          %{
            "task_ref" => task_ref,
            "status" => "in_progress",
            "add_tags" => ["beta"]
          },
          state
        )

      assert update_result.status == :ok
      assert update_result.content =~ "status"
      assert update_result.content =~ "tags"

      {:ok, get_result} = GetTask.execute(%{"task_ref" => task_ref}, state)
      assert get_result.content =~ "in_progress"
      assert get_result.content =~ "alpha, beta"
    end

    test "delete_task archives by short ref" do
      {user, conversation} = create_user_and_conversation()
      state = loop_state(user, conversation)

      {:ok, create_result} = CreateTask.execute(%{"title" => "Archive me"}, state)
      task_ref = create_result.metadata.task_ref

      {:ok, delete_result} =
        DeleteTask.execute(%{"task_ref" => task_ref, "reason" => "superseded"}, state)

      assert delete_result.status == :ok
      assert delete_result.content =~ "archived"
      assert delete_result.content =~ task_ref
    end
  end
end
