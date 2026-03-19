defmodule Assistant.Embeddings.UnifiedSearchTest do
  # Modifies Application env — must be async: false
  use Assistant.DataCase, async: false

  import Assistant.MemoryFixtures
  alias Assistant.Embeddings.UnifiedSearch

  setup do
    original = Application.get_env(:assistant, :embeddings, [])
    on_exit(fn -> Application.put_env(:assistant, :embeddings, original) end)
    :ok
  end

  describe "module exports" do
    test "exports search/2 and search/3" do
      Code.ensure_loaded!(UnifiedSearch)
      assert function_exported?(UnifiedSearch, :search, 2)
      assert function_exported?(UnifiedSearch, :search, 3)
    end

    test "exports search_documents/2 and search_documents/3" do
      Code.ensure_loaded!(UnifiedSearch)
      assert function_exported?(UnifiedSearch, :search_documents, 2)
      assert function_exported?(UnifiedSearch, :search_documents, 3)
    end

    test "exports search_folders/2 and search_folders/3" do
      Code.ensure_loaded!(UnifiedSearch)
      assert function_exported?(UnifiedSearch, :search_folders, 2)
      assert function_exported?(UnifiedSearch, :search_folders, 3)
    end

    test "exports merge_rrf/3" do
      Code.ensure_loaded!(UnifiedSearch)
      assert function_exported?(UnifiedSearch, :merge_rrf, 3)
    end
  end

  describe "merge_rrf/3" do
    test "merges two empty lists" do
      assert [] = UnifiedSearch.merge_rrf([], [], 10)
    end

    test "handles single list with other empty" do
      items = [%{id: "a", score: 0.9, text: "A"}, %{id: "b", score: 0.8, text: "B"}]
      result = UnifiedSearch.merge_rrf(items, [], 10)
      assert length(result) == 2
    end

    test "handles other list with first empty" do
      items = [%{id: "a", score: 0.9, text: "A"}]
      result = UnifiedSearch.merge_rrf([], items, 10)
      assert length(result) == 1
    end

    test "respects limit parameter" do
      items = for i <- 1..20, do: %{id: "item-#{i}", score: 1.0 / i, text: "Item #{i}"}
      result = UnifiedSearch.merge_rrf(items, [], 5)
      assert length(result) == 5
    end

    test "items appearing in both lists get higher RRF scores" do
      list_a = [
        %{id: "shared", score: 0.9, text: "Shared"},
        %{id: "a-only", score: 0.8, text: "A only"}
      ]

      list_b = [
        %{id: "shared", score: 0.9, text: "Shared"},
        %{id: "b-only", score: 0.8, text: "B only"}
      ]

      result = UnifiedSearch.merge_rrf(list_a, list_b, 10)

      # "shared" appears in both lists so its RRF score = 1/(60+1) + 1/(60+1) = 2/61
      # "a-only" and "b-only" each appear once: 1/(60+2) = 1/62 or 1/(60+1) = 1/61
      shared = Enum.find(result, fn r -> r.id == "shared" end)
      a_only = Enum.find(result, fn r -> r.id == "a-only" end)

      assert shared.score > a_only.score
    end

    test "preserves item data from first occurrence" do
      list_a = [%{id: "x", score: 0.5, text: "From A", extra: "data"}]
      list_b = [%{id: "y", score: 0.5, text: "From B"}]

      result = UnifiedSearch.merge_rrf(list_a, list_b, 10)
      x = Enum.find(result, fn r -> r.id == "x" end)
      assert x.text == "From A"
      assert x.extra == "data"
    end

    test "returns items sorted by descending RRF score" do
      # Items at lower ranks get lower RRF scores
      list_a =
        for i <- 1..5, do: %{id: "a-#{i}", score: 1.0 / i, text: "A #{i}"}

      list_b =
        for i <- 1..5, do: %{id: "b-#{i}", score: 1.0 / i, text: "B #{i}"}

      result = UnifiedSearch.merge_rrf(list_a, list_b, 10)
      scores = Enum.map(result, & &1.score)

      # Scores should be in descending order
      assert scores == Enum.sort(scores, :desc)
    end
  end

  describe "search_documents/3" do
    test "returns empty list when no documents ingested (arcana stub)" do
      user = user_fixture()
      results = UnifiedSearch.search_documents(user.id, "test query")
      assert results == []
    end

    test "returns empty list with custom limit" do
      user = user_fixture()
      results = UnifiedSearch.search_documents(user.id, "test query", limit: 5)
      assert results == []
    end
  end

  describe "search_folders/3" do
    test "returns empty list when embeddings disabled" do
      user = user_fixture()
      Application.put_env(:assistant, :embeddings, enabled: false)
      results = UnifiedSearch.search_folders(user.id, "test query")
      assert results == []
    end

    test "returns empty list when no folders have embeddings" do
      user = user_fixture()
      # With embeddings disabled, generate returns {:error, :embeddings_disabled}
      # which triggers the [] fallback in search_folders
      Application.put_env(:assistant, :embeddings, enabled: false)
      results = UnifiedSearch.search_folders(user.id, "test query")
      assert results == []
    end
  end
end
