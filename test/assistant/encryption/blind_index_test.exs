defmodule Assistant.Encryption.BlindIndexTest do
  use ExUnit.Case, async: true
  alias Assistant.Encryption.BlindIndex

  describe "tokenize/1" do
    test "downcases and extracts words ignoring punctuation" do
      text = "Hello, World! I'm indexing data: cost=$4.99."
      assert BlindIndex.tokenize(text) == ["hello", "world", "im", "indexing", "data", "cost499"]
    end
  end

  describe "generate_digest/2" do
    test "generates repeatable string digests" do
      digest1 = BlindIndex.generate_digest("hello", "org1")
      digest2 = BlindIndex.generate_digest("hello", "org1")
      digest3 = BlindIndex.generate_digest("hello", "org2")
      digest4 = BlindIndex.generate_digest("world", "org1")

      assert digest1 == digest2
      assert digest1 != digest3
      assert digest1 != digest4
      assert String.length(digest1) > 10
    end
  end

  describe "generate_digest/2 — false positive and isolation" do
    test "different terms produce different digests for the same billing_account_id" do
      # Common words that should never collide
      terms = ~w(hello world meeting project budget schedule report)
      billing_id = "org_fp_test"

      digests = Enum.map(terms, &BlindIndex.generate_digest(&1, billing_id))
      unique_digests = Enum.uniq(digests)

      assert length(unique_digests) == length(terms),
             "Expected #{length(terms)} unique digests but got #{length(unique_digests)}"
    end

    test "same term produces different digests for different billing_account_ids" do
      term = "confidential"
      ids = ~w(org_a org_b org_c org_d)

      digests = Enum.map(ids, &BlindIndex.generate_digest(term, &1))
      unique_digests = Enum.uniq(digests)

      assert length(unique_digests) == length(ids),
             "Expected #{length(ids)} unique digests but got #{length(unique_digests)} — cross-tenant isolation broken"
    end
  end

  describe "process_text/2" do
    test "yields frequency map of digests" do
      text = "Apple apple Banana"
      res = BlindIndex.process_text(text, "org1")

      apple_digest = BlindIndex.generate_digest("apple", "org1")
      banana_digest = BlindIndex.generate_digest("banana", "org1")

      assert res[apple_digest] == 2
      assert res[banana_digest] == 1
    end

    test "searching for term X does not match entries indexed with term Y" do
      billing_id = "org_fp_check"

      # Index with "alpha"
      alpha_digests = BlindIndex.process_text("alpha", billing_id)

      # Digests for "beta"
      beta_digests = BlindIndex.process_text("beta", billing_id)

      # No overlap — a search for "beta" should not find "alpha" entries
      alpha_keys = Map.keys(alpha_digests)
      beta_keys = Map.keys(beta_digests)

      overlap = MapSet.intersection(MapSet.new(alpha_keys), MapSet.new(beta_keys))

      assert MapSet.size(overlap) == 0,
             "False positive: digests for 'alpha' and 'beta' overlap: #{inspect(overlap)}"
    end
  end

  describe "matching_owner_ids/3" do
    test "returns empty list for nil or empty query text" do
      assert {:ok, []} = BlindIndex.matching_owner_ids(nil, "org1", "memory_entry")
      assert {:ok, []} = BlindIndex.matching_owner_ids("", "org1", "memory_entry")
    end
  end
end
