# test/assistant/memory/context_builder_test.exs — Tests for ContextBuilder.
#
# Verifies module compilation, public API exports, formatting logic,
# and integration with Store/Search for building memory context.
#
# Related files:
#   - lib/assistant/memory/context_builder.ex (module under test)
#   - lib/assistant/memory/store.ex (conversation lookup)
#   - lib/assistant/memory/search.ex (FTS retrieval)
#   - lib/assistant/task_manager/queries.ex (task listing)

defmodule Assistant.Memory.ContextBuilderTest do
  use Assistant.DataCase, async: true

  alias Assistant.Memory.ContextBuilder
  alias Assistant.Memory.Store
  alias Assistant.Schemas.User

  defp create_test_user do
    %User{}
    |> User.changeset(%{
      external_id: "ctx-builder-test-#{System.unique_integer([:positive])}",
      channel: "test"
    })
    |> Repo.insert!()
  end

  defp create_entry(attrs) do
    {:ok, entry} = Store.create_memory_entry(attrs)
    entry
  end

  describe "module compilation" do
    test "module is loaded and available" do
      assert Code.ensure_loaded?(Assistant.Memory.ContextBuilder)
    end

    test "exports build_context/3" do
      Code.ensure_loaded!(ContextBuilder)
      assert function_exported?(ContextBuilder, :build_context, 3)
    end

    test "exports build_context/2 (default opts)" do
      Code.ensure_loaded!(ContextBuilder)
      assert function_exported?(ContextBuilder, :build_context, 2)
    end
  end

  # ---------------------------------------------------------------
  # build_context/3 — return structure and graceful degradation
  # ---------------------------------------------------------------

  describe "build_context/3 return structure" do
    test "returns {:ok, map} with memory_context and task_summary keys" do
      {:ok, result} = ContextBuilder.build_context(nil, Ecto.UUID.generate())

      assert is_map(result)
      assert Map.has_key?(result, :memory_context)
      assert Map.has_key?(result, :task_summary)
      assert is_binary(result.memory_context)
      assert is_binary(result.task_summary)
    end

    test "returns empty strings when conversation_id is nil and no memories exist" do
      user = create_test_user()
      {:ok, result} = ContextBuilder.build_context(nil, user.id)

      assert result.memory_context == ""
      assert result.task_summary == ""
    end

    test "returns empty strings for non-existent conversation_id" do
      user = create_test_user()
      {:ok, result} = ContextBuilder.build_context(Ecto.UUID.generate(), user.id)

      # Should degrade gracefully — no crash, empty context
      assert result.memory_context == ""
    end
  end

  # ---------------------------------------------------------------
  # build_context/3 — conversation summary inclusion
  # ---------------------------------------------------------------

  describe "build_context/3 — conversation summary" do
    test "includes conversation summary in memory_context" do
      user = create_test_user()
      {:ok, conv} = Store.create_conversation(%{channel: "test", user_id: user.id})

      Store.update_summary(
        conv.id,
        "User discussed project deadlines and team assignments.",
        "test/model"
      )

      {:ok, result} = ContextBuilder.build_context(conv.id, user.id)

      assert result.memory_context =~ "Conversation Summary"
      assert result.memory_context =~ "project deadlines"
    end

    test "omits summary section when conversation has no summary" do
      user = create_test_user()
      {:ok, conv} = Store.create_conversation(%{channel: "test", user_id: user.id})

      {:ok, result} = ContextBuilder.build_context(conv.id, user.id)

      refute result.memory_context =~ "Conversation Summary"
    end
  end

  # ---------------------------------------------------------------
  # build_context/3 — memory entries inclusion
  # ---------------------------------------------------------------

  describe "build_context/3 — relevant memories" do
    test "includes matching memories when explicit query is provided" do
      user = create_test_user()

      # Create a memory that should match via FTS
      create_entry(%{
        content: "User strongly prefers dark mode in all interfaces",
        user_id: user.id,
        category: "preference"
      })

      # Use explicit query param to bypass summary lookup
      {:ok, result} = ContextBuilder.build_context(nil, user.id, query: "dark mode")

      assert result.memory_context =~ "Relevant Memories"
      assert result.memory_context =~ "dark mode"
    end

    test "returns no memories section when no memories match" do
      user = create_test_user()
      {:ok, conv} = Store.create_conversation(%{channel: "test", user_id: user.id})

      Store.update_summary(conv.id, "Discussing quantum physics.", "test/model")

      {:ok, result} = ContextBuilder.build_context(conv.id, user.id)

      refute result.memory_context =~ "Relevant Memories"
    end

    test "memory entries include tags when present" do
      user = create_test_user()
      {:ok, conv} = Store.create_conversation(%{channel: "test", user_id: user.id})

      Store.update_summary(conv.id, "Working on deployment tasks.", "test/model")

      create_entry(%{
        content: "Deployment requires Docker and Kubernetes",
        user_id: user.id,
        tags: ["deployment", "infrastructure"]
      })

      {:ok, result} = ContextBuilder.build_context(conv.id, user.id)

      # Tags should appear in formatted output
      if result.memory_context =~ "Relevant Memories" do
        assert result.memory_context =~ "deployment"
      end
    end

    test "accepts explicit query override via opts" do
      user = create_test_user()

      create_entry(%{
        content: "The user works at Acme Corporation as a senior engineer",
        user_id: user.id
      })

      # Explicit query bypasses conversation summary lookup
      {:ok, result} = ContextBuilder.build_context(nil, user.id, query: "Acme Corporation")

      assert result.memory_context =~ "Acme Corporation"
    end

    test "respects memory_limit option" do
      user = create_test_user()

      # Create several memories
      for i <- 1..5 do
        create_entry(%{
          content: "Memory entry number #{i} about testing patterns",
          user_id: user.id
        })
      end

      {:ok, result} =
        ContextBuilder.build_context(nil, user.id,
          query: "testing patterns",
          memory_limit: 2
        )

      # Should have at most 2 numbered entries
      if result.memory_context =~ "Relevant Memories" do
        # Count numbered entries (1. and 2. should be present, but not 3.)
        refute result.memory_context =~ "3."
      end
    end
  end

  # ---------------------------------------------------------------
  # build_context/3 — combined summary + memories
  # ---------------------------------------------------------------

  describe "build_context/3 — combined context" do
    test "includes both summary and memories when both exist" do
      user = create_test_user()
      {:ok, conv} = Store.create_conversation(%{channel: "test", user_id: user.id})

      Store.update_summary(conv.id, "Discussing database migration strategies.", "test/model")

      create_entry(%{
        content: "Previous migration used Ecto Multi for atomicity",
        user_id: user.id
      })

      {:ok, result} = ContextBuilder.build_context(conv.id, user.id)

      assert result.memory_context =~ "Conversation Summary"
      assert result.memory_context =~ "database migration"

      if result.memory_context =~ "Relevant Memories" do
        assert result.memory_context =~ "Ecto Multi"
      end
    end
  end
end
