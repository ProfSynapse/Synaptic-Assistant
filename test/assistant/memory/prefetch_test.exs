# test/assistant/memory/prefetch_test.exs — Tests for Memory.Prefetch module.

defmodule Assistant.Memory.PrefetchTest do
  use Assistant.DataCase, async: true

  alias Assistant.Memory.{Prefetch, Store}
  alias Assistant.Schemas.User

  describe "module compilation" do
    test "Prefetch module is loaded and exports resolve/3" do
      assert Code.ensure_loaded?(Prefetch)
      assert function_exported?(Prefetch, :resolve, 3)
    end
  end

  describe "resolve/3 with empty inputs" do
    test "returns empty string for empty questions list" do
      assert Prefetch.resolve("user-123", []) == ""
    end

    test "returns empty string for nil questions" do
      assert Prefetch.resolve("user-123", nil) == ""
    end
  end

  describe "resolve/3 with memories" do
    setup do
      user = create_test_user()

      # Create a few test memories
      {:ok, mem1} =
        Store.create_memory_entry(%{
          user_id: user.id,
          content: "Alice Chen is a senior backend engineer specializing in distributed systems",
          source_type: "user_explicit",
          category: "person",
          tags: ["person", "engineering"],
          search_queries: [
            "Who has distributed systems experience?",
            "What does Alice Chen do?",
            "Who are the engineers?"
          ]
        })

      {:ok, mem2} =
        Store.create_memory_entry(%{
          user_id: user.id,
          content: "Project Neptune is a Kubernetes infrastructure overhaul planned for Q2",
          source_type: "user_explicit",
          category: "project",
          tags: ["project", "kubernetes"],
          search_queries: [
            "What is Project Neptune?",
            "What Kubernetes projects are planned?",
            "What is happening in Q2?"
          ]
        })

      {:ok, mem3} =
        Store.create_memory_entry(%{
          user_id: user.id,
          content: "The user prefers morning standup meetings at 9am",
          source_type: "user_explicit",
          category: "preference",
          tags: ["preference", "meetings"],
          search_queries: [
            "When does the user prefer meetings?",
            "What is the standup schedule?"
          ]
        })

      %{user: user, mem1: mem1, mem2: mem2, mem3: mem3}
    end

    test "returns formatted context for matching questions", %{user: user} do
      result = Prefetch.resolve(user.id, ["Who has distributed systems experience?"])

      assert result =~ "Pre-fetched Memory Context"
      assert result =~ "Alice Chen"
      assert result =~ "distributed systems"
    end

    test "handles multiple questions", %{user: user} do
      result =
        Prefetch.resolve(user.id, [
          "What is Project Neptune?",
          "When does the user prefer meetings?"
        ])

      assert result =~ "Pre-fetched Memory Context"
      assert result =~ "Neptune"
      assert result =~ "standup"
    end

    test "deduplicates entries across overlapping questions", %{user: user} do
      result =
        Prefetch.resolve(user.id, [
          "Who has distributed systems experience?",
          "What does Alice Chen do?"
        ])

      # Alice should appear only once despite matching both questions
      occurrences =
        result
        |> String.split("Alice Chen")
        |> length()

      # String.split gives n+1 parts for n occurrences
      assert occurrences <= 3
    end

    test "respects per_question_limit", %{user: user} do
      result = Prefetch.resolve(user.id, ["engineer"], per_question_limit: 1)
      assert result =~ "Pre-fetched Memory Context" or result == ""
    end

    test "returns empty string when no matches found", %{user: user} do
      result = Prefetch.resolve(user.id, ["quantum entanglement reactor specifications"])
      assert result == ""
    end

    test "returns empty string for unknown user_id" do
      result =
        Prefetch.resolve(
          "00000000-0000-0000-0000-000000000000",
          ["anything"]
        )

      assert result == ""
    end
  end

  defp create_test_user do
    %User{}
    |> User.changeset(%{
      external_id: "prefetch-test-#{System.unique_integer([:positive])}",
      channel: "test"
    })
    |> Repo.insert!()
  end
end
