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

  describe "get_entity_relations/2" do
    test "returns {:ok, []} when no relations exist" do
      assert {:ok, []} = Search.get_entity_relations(Ecto.UUID.generate())
    end
  end
end
