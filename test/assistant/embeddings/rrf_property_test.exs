# test/assistant/embeddings/rrf_property_test.exs
#
# Property-based tests for merge_rrf/3 — verifies mathematical invariants
# hold across randomly generated ranked lists using StreamData.
#
# Invariants verified:
#   1. Output length never exceeds the limit parameter
#   2. All RRF scores are positive (sum of 1/(k+rank) terms)
#   3. Output is sorted by descending score
#   4. RRF score formula: score = sum(1/(60+rank_i)) for each occurrence
#   5. Items appearing in both lists always outscore same-ranked single-list items
#   6. Empty inputs produce empty output

defmodule Assistant.Embeddings.RRFPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Assistant.Embeddings.UnifiedSearch

  @rrf_k 60

  # ---------------------------------------------------------------
  # Generators
  # ---------------------------------------------------------------

  # Generate a ranked list of items with unique IDs and decreasing scores
  defp ranked_list_gen do
    gen all(
          len <- integer(0..30),
          ids <- list_of(positive_integer(), length: len)
        ) do
      ids
      |> Enum.with_index(1)
      |> Enum.map(fn {seed, rank} ->
        %{id: "item-#{seed}", score: 1.0 / rank, text: "Text #{seed}"}
      end)
    end
  end

  # Generate a list with guaranteed unique IDs
  defp unique_ranked_list_gen do
    gen all(
          len <- integer(1..20),
          base <- positive_integer()
        ) do
      for i <- 1..len do
        %{id: "u-#{base}-#{i}", score: 1.0 / i, text: "Unique #{i}"}
      end
    end
  end

  # Generate a limit parameter
  defp limit_gen do
    integer(1..50)
  end

  # ---------------------------------------------------------------
  # Property: output length never exceeds limit
  # ---------------------------------------------------------------

  property "output length never exceeds limit" do
    check all(
            list_a <- ranked_list_gen(),
            list_b <- ranked_list_gen(),
            limit <- limit_gen()
          ) do
      result = UnifiedSearch.merge_rrf(list_a, list_b, limit)
      assert length(result) <= limit
    end
  end

  # ---------------------------------------------------------------
  # Property: all RRF scores are positive
  # ---------------------------------------------------------------

  property "all RRF scores are positive" do
    check all(
            list_a <- ranked_list_gen(),
            list_b <- ranked_list_gen(),
            limit <- limit_gen()
          ) do
      result = UnifiedSearch.merge_rrf(list_a, list_b, limit)

      Enum.each(result, fn item ->
        assert item.score > 0, "Expected positive score, got #{item.score}"
      end)
    end
  end

  # ---------------------------------------------------------------
  # Property: output is always sorted by descending score
  # ---------------------------------------------------------------

  property "output is sorted by descending score" do
    check all(
            list_a <- ranked_list_gen(),
            list_b <- ranked_list_gen(),
            limit <- limit_gen()
          ) do
      result = UnifiedSearch.merge_rrf(list_a, list_b, limit)
      scores = Enum.map(result, & &1.score)
      assert scores == Enum.sort(scores, :desc)
    end
  end

  # ---------------------------------------------------------------
  # Property: RRF score matches formula 1/(k+rank) summed across lists
  # ---------------------------------------------------------------

  property "RRF scores match 1/(k+rank) formula" do
    check all(
            list_a <- unique_ranked_list_gen(),
            list_b <- unique_ranked_list_gen()
          ) do
      result = UnifiedSearch.merge_rrf(list_a, list_b, 100)

      # Build expected scores from the formula
      expected_scores = %{}

      expected_scores =
        list_a
        |> Enum.with_index(1)
        |> Enum.reduce(expected_scores, fn {item, rank}, acc ->
          Map.update(acc, item.id, 1.0 / (@rrf_k + rank), &(&1 + 1.0 / (@rrf_k + rank)))
        end)

      expected_scores =
        list_b
        |> Enum.with_index(1)
        |> Enum.reduce(expected_scores, fn {item, rank}, acc ->
          Map.update(acc, item.id, 1.0 / (@rrf_k + rank), &(&1 + 1.0 / (@rrf_k + rank)))
        end)

      Enum.each(result, fn item ->
        expected = Map.get(expected_scores, item.id)
        assert expected != nil, "Item #{item.id} not found in expected scores"

        assert_in_delta item.score,
                        expected,
                        1.0e-10,
                        "Score mismatch for #{item.id}: got #{item.score}, expected #{expected}"
      end)
    end
  end

  # ---------------------------------------------------------------
  # Property: items in both lists outscore same-ranked single-list items
  # ---------------------------------------------------------------

  property "items appearing in both lists outscore single-list items at same rank" do
    check all(
            base <- positive_integer(),
            rank <- integer(1..20)
          ) do
      shared_item = %{id: "shared-#{base}", score: 0.5, text: "Shared"}
      single_item = %{id: "single-#{base}", score: 0.5, text: "Single"}

      # Place shared at the given rank in both lists, single at same rank in one list
      list_a = pad_list(rank, shared_item) ++ pad_list(rank, single_item)
      list_b = pad_list(rank, shared_item)

      result = UnifiedSearch.merge_rrf(list_a, list_b, 100)

      shared = Enum.find(result, fn r -> r.id == "shared-#{base}" end)
      single = Enum.find(result, fn r -> r.id == "single-#{base}" end)

      assert shared != nil
      assert single != nil

      assert shared.score > single.score,
             "Shared score #{shared.score} should exceed single score #{single.score}"
    end
  end

  # ---------------------------------------------------------------
  # Property: empty inputs always produce empty output
  # ---------------------------------------------------------------

  property "empty inputs produce empty output" do
    check all(limit <- limit_gen()) do
      assert [] = UnifiedSearch.merge_rrf([], [], limit)
    end
  end

  # ---------------------------------------------------------------
  # Property: output IDs are a subset of input IDs
  # ---------------------------------------------------------------

  property "output IDs are a subset of input IDs" do
    check all(
            list_a <- ranked_list_gen(),
            list_b <- ranked_list_gen(),
            limit <- limit_gen()
          ) do
      result = UnifiedSearch.merge_rrf(list_a, list_b, limit)

      input_ids = MapSet.new(Enum.map(list_a ++ list_b, & &1.id))
      output_ids = MapSet.new(Enum.map(result, & &1.id))

      assert MapSet.subset?(output_ids, input_ids)
    end
  end

  # ---------------------------------------------------------------
  # Property: scores always decrease with rank (single-list monotonicity)
  # ---------------------------------------------------------------

  property "single-list RRF scores decrease with rank" do
    check all(len <- integer(2..20), base <- positive_integer()) do
      list =
        for i <- 1..len do
          %{id: "mono-#{base}-#{i}", score: 1.0 / i, text: "Item #{i}"}
        end

      result = UnifiedSearch.merge_rrf(list, [], 100)

      # For unique IDs from a single list, score = 1/(k+rank)
      # Items at lower ranks should have lower scores
      scores = Enum.map(result, & &1.score)
      assert scores == Enum.sort(scores, :desc)

      # First item should have score 1/(k+1) and last should have 1/(k+len)
      if length(result) > 0 do
        assert_in_delta hd(result).score, 1.0 / (@rrf_k + 1), 1.0e-10
        assert_in_delta List.last(result).score, 1.0 / (@rrf_k + len), 1.0e-10
      end
    end
  end

  # ---------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------

  # Build a list where the target item appears at the given rank (1-indexed)
  # by inserting filler items before it
  defp pad_list(1, item), do: [item]

  defp pad_list(rank, item) when rank > 1 do
    fillers =
      for i <- 1..(rank - 1) do
        %{id: "filler-#{:erlang.phash2({item.id, i})}", score: 0.1, text: "Filler"}
      end

    fillers ++ [item]
  end
end
