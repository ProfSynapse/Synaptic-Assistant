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

  describe "process_text/2" do
    test "yields frequency map of digests" do
      text = "Apple apple Banana"
      res = BlindIndex.process_text(text, "org1")
      
      apple_digest = BlindIndex.generate_digest("apple", "org1")
      banana_digest = BlindIndex.generate_digest("banana", "org1")

      assert res[apple_digest] == 2
      assert res[banana_digest] == 1
    end
  end
end
