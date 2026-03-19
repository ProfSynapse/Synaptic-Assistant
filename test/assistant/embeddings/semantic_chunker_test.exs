defmodule Assistant.Embeddings.SemanticChunkerTest do
  use ExUnit.Case, async: true

  alias Assistant.Embeddings.SemanticChunker

  describe "chunk/2 with empty input" do
    test "returns empty list for empty string" do
      assert [] = SemanticChunker.chunk("")
    end

    test "returns empty list for whitespace-only string" do
      assert [] = SemanticChunker.chunk("   \n\n  ")
    end
  end

  describe "chunk/2 with single sentence" do
    test "returns single chunk for one sentence" do
      result = SemanticChunker.chunk("The quick brown fox jumps over the lazy dog.")
      assert length(result) == 1
      [chunk] = result
      assert chunk.text == "The quick brown fox jumps over the lazy dog."
      assert chunk.chunk_index == 0
      assert is_integer(chunk.token_count)
      assert chunk.token_count > 0
      assert chunk.source_type == :plain
      assert chunk.header_path == nil
    end
  end

  describe "chunk/2 fallback behavior (embeddings disabled)" do
    test "produces chunks from multiple sentences when embeddings disabled" do
      text = "First sentence about Elixir. Second sentence about Phoenix. Third sentence about OTP."
      result = SemanticChunker.chunk(text)

      # With embeddings disabled, all similarities default to 1.0 (no boundaries)
      # so everything merges into one chunk
      assert length(result) >= 1
      # All original content should be present
      full_text = Enum.map_join(result, " ", & &1.text)
      assert String.contains?(full_text, "Elixir")
      assert String.contains?(full_text, "Phoenix")
      assert String.contains?(full_text, "OTP")
    end
  end

  describe "chunk/2 metadata" do
    test "includes chunk_index, token_count, source_type, header_path" do
      result = SemanticChunker.chunk("A short sentence.")
      [chunk] = result

      assert Map.has_key?(chunk, :text)
      assert Map.has_key?(chunk, :chunk_index)
      assert Map.has_key?(chunk, :token_count)
      assert Map.has_key?(chunk, :source_type)
      assert Map.has_key?(chunk, :header_path)
    end

    test "token_count is approximately byte_size / 4" do
      text = "This is a test sentence with some words."
      [chunk] = SemanticChunker.chunk(text)
      expected = div(byte_size(text), 4)
      assert chunk.token_count == expected
    end
  end

  describe "chunk/2 with markdown" do
    test "detects markdown source_type when headers present after newline" do
      # source_type detection checks String.contains?(original_text, "\\n#")
      text = "Some intro text.\n# Introduction\nThis is the intro.\n\n## Details\nSome details here."
      result = SemanticChunker.chunk(text)
      assert Enum.any?(result, fn chunk -> chunk.source_type == :markdown end)
    end

    test "extracts header path from markdown" do
      text = "Some preamble.\n# Overview\nSome text here.\n\n## Setup\nSetup instructions."
      result = SemanticChunker.chunk(text)
      chunk_with_path = Enum.find(result, fn c -> c.header_path != nil end)
      assert chunk_with_path != nil
      assert String.contains?(chunk_with_path.header_path, "Overview")
    end

    test "plain source_type when no newline-preceded headers" do
      text = "Just a plain sentence. And another one."
      result = SemanticChunker.chunk(text)
      Enum.each(result, fn chunk ->
        assert chunk.source_type == :plain
      end)
    end
  end

  describe "chunk/2 size enforcement" do
    test "very long text produces chunks with reasonable token counts" do
      # Generate text well over 450 tokens (~1800 chars)
      long_text = String.duplicate("This is a fairly long sentence with many words in it. ", 50)
      result = SemanticChunker.chunk(long_text)

      # Should produce at least one chunk
      assert length(result) >= 1

      # Each chunk should have a token count
      Enum.each(result, fn chunk ->
        assert is_integer(chunk.token_count)
        assert chunk.token_count > 0
      end)
    end

    test "chunk indices are sequential starting from 0" do
      text = "First sentence. Second sentence. Third sentence."
      result = SemanticChunker.chunk(text)
      indices = Enum.map(result, & &1.chunk_index)
      assert indices == Enum.to_list(0..(length(result) - 1))
    end
  end
end
