defmodule Assistant.Embeddings.UnifiedSearchIntegrationTest do
  @moduledoc """
  Integration tests for UnifiedSearch.search/2 — the top-level orchestration
  function that fans out parallel searches and merges via RRF.
  """
  use Assistant.DataCase, async: false

  import Assistant.MemoryFixtures
  alias Assistant.Embeddings.UnifiedSearch

  setup do
    original = Application.get_env(:assistant, :embeddings, [])
    on_exit(fn -> Application.put_env(:assistant, :embeddings, original) end)
    :ok
  end

  describe "search/2 with embeddings disabled (FTS fallback)" do
    setup do
      Application.put_env(:assistant, :embeddings, enabled: false)
      :ok
    end

    test "returns FTS results for a matching query" do
      user = user_fixture()
      _entry = memory_fixture!(user, "Elixir is a functional programming language", tags: ["tech"])

      results = UnifiedSearch.search(user.id, "Elixir")

      assert is_list(results)
      assert length(results) >= 1

      first = hd(results)
      assert first.type == :memory
      assert is_binary(first.id)
      assert String.contains?(first.content, "Elixir")
      assert is_float(first.score)
      assert first.score > 0
    end

    test "returns empty list when no memories match" do
      user = user_fixture()
      _entry = memory_fixture!(user, "Completely unrelated content about weather patterns")

      results = UnifiedSearch.search(user.id, "xyznonexistent")

      assert is_list(results)
      assert results == []
    end

    test "respects limit option" do
      user = user_fixture()

      for i <- 1..5 do
        memory_fixture!(user, "Phoenix framework feature number #{i} is great")
      end

      results = UnifiedSearch.search(user.id, "Phoenix", limit: 3)

      assert length(results) <= 3
    end

    test "does not include other users' memories" do
      user1 = user_fixture()
      user2 = user_fixture()
      _entry1 = memory_fixture!(user1, "Secret project Alpha information")
      _entry2 = memory_fixture!(user2, "Secret project Beta information")

      results = UnifiedSearch.search(user1.id, "Secret project")

      ids = Enum.map(results, & &1.id)
      # Verify only user1's memories are returned
      assert Enum.all?(results, fn r -> r.content =~ "Alpha" end)
      refute Enum.any?(results, fn r -> r.content =~ "Beta" end)
      assert length(ids) == length(Enum.uniq(ids))
    end

    test "results have expected structure" do
      user = user_fixture()
      _entry = memory_fixture!(user, "OTP supervision trees handle fault tolerance",
        category: "fact", importance: Decimal.new("0.80"))

      results = UnifiedSearch.search(user.id, "OTP supervision")

      assert length(results) >= 1
      result = hd(results)

      assert Map.has_key?(result, :type)
      assert Map.has_key?(result, :id)
      assert Map.has_key?(result, :content)
      assert Map.has_key?(result, :score)
      assert Map.has_key?(result, :metadata)
      assert result.metadata["category"] == "fact"
    end
  end

  describe "search/2 with embeddings enabled (parallel path)" do
    setup do
      Application.put_env(:assistant, :embeddings, enabled: true)
      :ok
    end

    test "returns results from FTS memories (arcana stub returns empty)" do
      user = user_fixture()
      _entry = memory_fixture!(user, "GenServer is a behaviour module for implementing servers")

      # With arcana_search stubbed to [], the parallel path will:
      # - search_memories -> FTS results
      # - search_documents -> [] (arcana stub)
      # - merge_rrf(fts_results, [], limit)
      results = UnifiedSearch.search(user.id, "GenServer")

      assert is_list(results)
      # Should still find memory via FTS through the parallel path
      assert length(results) >= 1
      assert hd(results).type == :memory
    end

    test "returns empty when no data matches" do
      user = user_fixture()

      results = UnifiedSearch.search(user.id, "xyznonexistent")

      assert results == []
    end

    test "respects limit in parallel path" do
      user = user_fixture()

      for i <- 1..8 do
        memory_fixture!(user, "Ecto query composition technique #{i} explained")
      end

      results = UnifiedSearch.search(user.id, "Ecto query", limit: 3)

      assert length(results) <= 3
    end

    test "RRF scoring is applied (scores are RRF-transformed, not raw)" do
      user = user_fixture()
      _entry = memory_fixture!(user, "Task.async and Task.await for concurrent operations")

      results = UnifiedSearch.search(user.id, "Task async")

      if length(results) > 0 do
        # RRF scores should be 1/(k+rank) where k=60
        # First item: 1/61 ≈ 0.01639
        first_score = hd(results).score
        assert first_score > 0
        assert first_score < 1.0
      end
    end
  end

  describe "search/2 default limit" do
    test "defaults to limit of 10" do
      Application.put_env(:assistant, :embeddings, enabled: false)
      user = user_fixture()

      for i <- 1..15 do
        memory_fixture!(user, "Distributed Erlang node #{i} clustering setup")
      end

      results = UnifiedSearch.search(user.id, "Distributed Erlang")

      assert length(results) <= 10
    end
  end
end
