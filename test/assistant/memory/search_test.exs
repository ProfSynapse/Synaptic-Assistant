# test/assistant/memory/search_test.exs — Smoke tests for Memory.Search.
#
# Verifies the module compiles, exports expected functions, and basic
# query construction is valid. Comprehensive DB integration tests belong
# in the TEST phase.

defmodule Assistant.Memory.SearchTest do
  use Assistant.DataCase, async: true

  alias Assistant.Memory.Search
  alias Assistant.Schemas.{MemoryEntity, MemoryEntry, User}

  describe "module compilation" do
    test "Search module is loaded and exports expected functions" do
      assert Code.ensure_loaded?(Search)
      assert function_exported?(Search, :search_memories, 2)
      assert function_exported?(Search, :search_by_tags, 2)
      assert function_exported?(Search, :get_recent_entries, 2)
      assert function_exported?(Search, :search_entities, 2)
      assert function_exported?(Search, :get_entity_relations, 2)
    end
  end

  defp create_test_user do
    %User{}
    |> User.changeset(%{
      external_id: "search-test-#{System.unique_integer([:positive])}",
      channel: "test"
    })
    |> Repo.insert!()
  end

  describe "search_memories/2" do
    test "returns {:ok, []} when no entries exist" do
      user = create_test_user()
      assert {:ok, []} = Search.search_memories(user.id, query: "nonexistent")
    end

    test "returns {:ok, entries} for matching FTS query" do
      user = create_test_user()

      %MemoryEntry{}
      |> MemoryEntry.changeset(%{
        content: "The user prefers dark mode for all interfaces",
        user_id: user.id,
        category: "preference"
      })
      |> Repo.insert!()

      assert {:ok, results} = Search.search_memories(user.id, query: "dark mode")
      assert length(results) == 1
      assert hd(results).content =~ "dark mode"
    end

    test "matches a memory by title" do
      user = create_test_user()

      %MemoryEntry{}
      |> MemoryEntry.changeset(%{
        title: "Dark mode preference",
        content: "The user prefers dark mode for all interfaces",
        user_id: user.id,
        category: "preference"
      })
      |> Repo.insert!()

      assert {:ok, results} = Search.search_memories(user.id, query: "preference")
      assert length(results) == 1
      assert hd(results).title == "Dark mode preference"
    end

    test "filters by tags" do
      user = create_test_user()

      %MemoryEntry{}
      |> MemoryEntry.changeset(%{
        content: "Meeting notes from standup",
        user_id: user.id,
        tags: ["meeting", "standup"]
      })
      |> Repo.insert!()

      %MemoryEntry{}
      |> MemoryEntry.changeset(%{
        content: "User likes coffee",
        user_id: user.id,
        tags: ["preference"]
      })
      |> Repo.insert!()

      assert {:ok, results} = Search.search_memories(user.id, tags: ["meeting"])
      assert length(results) == 1
      assert hd(results).content =~ "standup"
    end

    test "respects limit" do
      user = create_test_user()

      for i <- 1..5 do
        %MemoryEntry{}
        |> MemoryEntry.changeset(%{content: "entry #{i}", user_id: user.id})
        |> Repo.insert!()
      end

      assert {:ok, results} = Search.search_memories(user.id, limit: 2)
      assert length(results) == 2
    end
  end

  describe "search_by_tags/2" do
    test "returns {:ok, []} for empty tags list" do
      user = create_test_user()
      assert {:ok, []} = Search.search_by_tags(user.id, [])
    end

    test "returns entries matching all specified tags" do
      user = create_test_user()

      %MemoryEntry{}
      |> MemoryEntry.changeset(%{
        content: "tagged entry",
        user_id: user.id,
        tags: ["alpha", "beta", "gamma"]
      })
      |> Repo.insert!()

      assert {:ok, results} = Search.search_by_tags(user.id, ["alpha", "beta"])
      assert length(results) == 1
    end
  end

  describe "get_recent_entries/2" do
    test "returns entries ordered by most recent" do
      user = create_test_user()

      for i <- 1..3 do
        %MemoryEntry{}
        |> MemoryEntry.changeset(%{content: "recent #{i}", user_id: user.id})
        |> Repo.insert!()
      end

      assert {:ok, results} = Search.get_recent_entries(user.id, 2)
      assert length(results) == 2
    end
  end

  describe "search_entities/2" do
    test "returns {:ok, []} when no entities exist" do
      user = create_test_user()
      assert {:ok, []} = Search.search_entities(user.id, name: "nobody")
    end

    test "finds entities by name fragment (case-insensitive)" do
      user = create_test_user()

      %MemoryEntity{}
      |> MemoryEntity.changeset(%{
        name: "Alice Johnson",
        entity_type: "person",
        user_id: user.id
      })
      |> Repo.insert!()

      assert {:ok, results} = Search.search_entities(user.id, name: "alice")
      assert length(results) == 1
      assert hd(results).name == "Alice Johnson"
    end

    test "filters by entity_type" do
      user = create_test_user()

      %MemoryEntity{}
      |> MemoryEntity.changeset(%{
        name: "Acme Corp",
        entity_type: "organization",
        user_id: user.id
      })
      |> Repo.insert!()

      %MemoryEntity{}
      |> MemoryEntity.changeset(%{name: "Acme Project", entity_type: "project", user_id: user.id})
      |> Repo.insert!()

      assert {:ok, results} =
               Search.search_entities(user.id, name: "acme", entity_type: "organization")

      assert length(results) == 1
      assert hd(results).entity_type == "organization"
    end
  end

  describe "search_memories/2 — advanced filtering" do
    test "combines FTS query with category filter" do
      user = create_test_user()

      %MemoryEntry{}
      |> MemoryEntry.changeset(%{
        content: "User prefers dark mode for coding",
        user_id: user.id,
        category: "preference"
      })
      |> Repo.insert!()

      %MemoryEntry{}
      |> MemoryEntry.changeset(%{
        content: "Dark mode configuration for terminal",
        user_id: user.id,
        category: "technical"
      })
      |> Repo.insert!()

      assert {:ok, results} =
               Search.search_memories(user.id, query: "dark mode", category: "preference")

      assert length(results) == 1
      assert hd(results).category == "preference"
    end

    test "filters by minimum importance threshold" do
      user = create_test_user()

      %MemoryEntry{}
      |> MemoryEntry.changeset(%{
        content: "Low importance fact about colors",
        user_id: user.id,
        importance: Decimal.new("0.20")
      })
      |> Repo.insert!()

      %MemoryEntry{}
      |> MemoryEntry.changeset(%{
        content: "High importance fact about deadlines",
        user_id: user.id,
        importance: Decimal.new("0.90")
      })
      |> Repo.insert!()

      assert {:ok, results} = Search.search_memories(user.id, importance_min: 0.5)
      assert length(results) == 1
      assert hd(results).content =~ "deadlines"
    end

    test "returns results scoped to the user only" do
      user1 = create_test_user()
      user2 = create_test_user()

      %MemoryEntry{}
      |> MemoryEntry.changeset(%{
        content: "User one favorite programming language is Elixir",
        user_id: user1.id
      })
      |> Repo.insert!()

      %MemoryEntry{}
      |> MemoryEntry.changeset(%{
        content: "User two favorite programming language is Python",
        user_id: user2.id
      })
      |> Repo.insert!()

      assert {:ok, results} = Search.search_memories(user1.id, query: "programming language")
      assert length(results) == 1
      assert hd(results).content =~ "Elixir"
    end

    test "returns results ordered by recency when no FTS query" do
      user = create_test_user()

      {:ok, _} =
        %MemoryEntry{}
        |> MemoryEntry.changeset(%{content: "older entry about testing", user_id: user.id})
        |> Repo.insert()

      Process.sleep(5)

      {:ok, _} =
        %MemoryEntry{}
        |> MemoryEntry.changeset(%{content: "newer entry about testing", user_id: user.id})
        |> Repo.insert()

      assert {:ok, results} = Search.search_memories(user.id)
      assert length(results) == 2
      # Most recent first when no FTS
      assert Enum.at(results, 0).content =~ "newer"
    end

    test "touches accessed_at on returned entries" do
      user = create_test_user()

      {:ok, entry} =
        %MemoryEntry{}
        |> MemoryEntry.changeset(%{
          content: "Testing accessed at timestamp tracking",
          user_id: user.id
        })
        |> Repo.insert()

      original_accessed_at = entry.accessed_at

      # Search should touch accessed_at
      {:ok, _results} = Search.search_memories(user.id, query: "accessed timestamp")

      # Reload the entry to check accessed_at was updated
      updated = Repo.get!(MemoryEntry, entry.id)
      assert updated.accessed_at != nil

      if original_accessed_at do
        assert DateTime.compare(updated.accessed_at, original_accessed_at) != :lt
      end
    end
  end

  describe "search_by_tags/2 — edge cases" do
    test "requires ALL specified tags to match (AND semantics)" do
      user = create_test_user()

      %MemoryEntry{}
      |> MemoryEntry.changeset(%{
        content: "has only alpha",
        user_id: user.id,
        tags: ["alpha"]
      })
      |> Repo.insert!()

      %MemoryEntry{}
      |> MemoryEntry.changeset(%{
        content: "has alpha and beta",
        user_id: user.id,
        tags: ["alpha", "beta"]
      })
      |> Repo.insert!()

      # Searching for both alpha AND beta should only return the second entry
      assert {:ok, results} = Search.search_by_tags(user.id, ["alpha", "beta"])
      assert length(results) == 1
      assert hd(results).content =~ "alpha and beta"
    end

    test "returns {:ok, []} when tag combination doesn't match any entry" do
      user = create_test_user()

      %MemoryEntry{}
      |> MemoryEntry.changeset(%{
        content: "has different tags",
        user_id: user.id,
        tags: ["x", "y"]
      })
      |> Repo.insert!()

      assert {:ok, []} = Search.search_by_tags(user.id, ["nonexistent_tag"])
    end
  end

  describe "search_entities/2 — edge cases" do
    test "returns multiple matching entities" do
      user = create_test_user()

      %MemoryEntity{}
      |> MemoryEntity.changeset(%{
        name: "Alice Smith",
        entity_type: "person",
        user_id: user.id
      })
      |> Repo.insert!()

      %MemoryEntity{}
      |> MemoryEntity.changeset(%{
        name: "Alice Johnson",
        entity_type: "person",
        user_id: user.id
      })
      |> Repo.insert!()

      assert {:ok, results} = Search.search_entities(user.id, name: "alice")
      assert length(results) == 2
    end

    test "respects limit" do
      user = create_test_user()

      for i <- 1..5 do
        %MemoryEntity{}
        |> MemoryEntity.changeset(%{
          name: "Entity #{i}",
          entity_type: "concept",
          user_id: user.id
        })
        |> Repo.insert!()
      end

      assert {:ok, results} = Search.search_entities(user.id, limit: 2)
      assert length(results) == 2
    end

    test "returns entities ordered by name ascending" do
      user = create_test_user()

      %MemoryEntity{}
      |> MemoryEntity.changeset(%{
        name: "Zebra Corp",
        entity_type: "organization",
        user_id: user.id
      })
      |> Repo.insert!()

      %MemoryEntity{}
      |> MemoryEntity.changeset(%{
        name: "Alpha Inc",
        entity_type: "organization",
        user_id: user.id
      })
      |> Repo.insert!()

      assert {:ok, results} = Search.search_entities(user.id)
      assert Enum.at(results, 0).name == "Alpha Inc"
      assert Enum.at(results, 1).name == "Zebra Corp"
    end
  end

  describe "get_entity_relations/2" do
    test "returns {:ok, []} when no relations exist" do
      assert {:ok, []} = Search.get_entity_relations(Ecto.UUID.generate())
    end
  end

  describe "get_recent_entries/2 — edge cases" do
    test "returns entries most recent first" do
      user = create_test_user()

      {:ok, _} =
        %MemoryEntry{}
        |> MemoryEntry.changeset(%{content: "older", user_id: user.id})
        |> Repo.insert()

      Process.sleep(5)

      {:ok, _} =
        %MemoryEntry{}
        |> MemoryEntry.changeset(%{content: "newer", user_id: user.id})
        |> Repo.insert()

      assert {:ok, results} = Search.get_recent_entries(user.id, 10)
      assert length(results) == 2
      assert Enum.at(results, 0).content == "newer"
      assert Enum.at(results, 1).content == "older"
    end

    test "respects limit parameter" do
      user = create_test_user()

      for i <- 1..5 do
        %MemoryEntry{}
        |> MemoryEntry.changeset(%{content: "entry #{i}", user_id: user.id})
        |> Repo.insert!()
      end

      assert {:ok, results} = Search.get_recent_entries(user.id, 2)
      assert length(results) == 2
    end

    test "returns {:ok, []} for user with no entries" do
      user = create_test_user()
      assert {:ok, []} = Search.get_recent_entries(user.id, 10)
    end
  end
end
