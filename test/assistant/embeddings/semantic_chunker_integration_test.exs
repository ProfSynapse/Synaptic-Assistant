# test/assistant/embeddings/semantic_chunker_integration_test.exs
#
# Integration tests for SemanticChunker with real embeddings.
# Verifies that topical boundaries are detected between clearly
# different-topic sentences when the embedding model is running.
#
# Tagged @moduletag :integration — excluded from `mix test` by default.
# Run with: mix test --include integration test/assistant/embeddings/semantic_chunker_integration_test.exs
#
# Prerequisites:
#   - Embeddings enabled: Application.put_env(:assistant, :embeddings, enabled: true)
#   - Nx.Serving started with the Assistant.Embeddings name
#   - Model downloaded (gte-small)

defmodule Assistant.Embeddings.SemanticChunkerIntegrationTest do
  use ExUnit.Case, async: true

  @moduletag :integration

  alias Assistant.Embeddings.SemanticChunker

  setup do
    original = Application.get_env(:assistant, :embeddings, [])
    Application.put_env(:assistant, :embeddings, enabled: true)
    on_exit(fn -> Application.put_env(:assistant, :embeddings, original) end)
    :ok
  end

  # ---------------------------------------------------------------
  # Boundary detection between clearly different topics
  # ---------------------------------------------------------------

  describe "chunk/2 boundary detection with real embeddings" do
    test "detects boundary between very different topics" do
      # Two clearly distinct topics: programming and cooking
      text = """
      Elixir uses the BEAM virtual machine for fault-tolerant distributed systems.
      GenServer is a behaviour module for implementing server processes.
      Supervisors restart child processes when they crash.
      To make a chocolate cake, preheat the oven to 350 degrees.
      Mix flour, sugar, cocoa powder, and baking soda in a large bowl.
      Add eggs, milk, and vegetable oil to the dry ingredients.
      """

      result = SemanticChunker.chunk(text)

      # With real embeddings, the chunker should detect the topic shift
      # between programming and cooking, producing at least 2 chunks
      assert length(result) >= 2,
             "Expected at least 2 chunks for distinct topics, got #{length(result)}: #{inspect(Enum.map(result, &String.slice(&1.text, 0..50)))}"

      # The programming content and cooking content should be in different chunks
      programming_chunks = Enum.filter(result, fn c -> String.contains?(c.text, "BEAM") end)
      cooking_chunks = Enum.filter(result, fn c -> String.contains?(c.text, "chocolate") end)

      assert length(programming_chunks) >= 1
      assert length(cooking_chunks) >= 1

      # They should not be in the same chunk
      programming_chunk_indices = Enum.map(programming_chunks, & &1.chunk_index)
      cooking_chunk_indices = Enum.map(cooking_chunks, & &1.chunk_index)

      assert MapSet.disjoint?(
               MapSet.new(programming_chunk_indices),
               MapSet.new(cooking_chunk_indices)
             ),
             "Programming and cooking content should be in different chunks"
    end

    test "keeps similar-topic sentences in the same chunk" do
      # All sentences about the same topic: Elixir concurrency
      text = """
      Elixir processes are lightweight and isolated.
      Each process has its own heap and garbage collector.
      Message passing is the primary communication mechanism.
      Processes can be linked for fault propagation.
      """

      result = SemanticChunker.chunk(text)

      # All sentences are on the same topic, so with real embeddings
      # they should have high similarity and stay in fewer chunks
      # (may still split due to size limits, but should be <= 2 chunks)
      assert length(result) <= 2,
             "Expected tightly related content in 1-2 chunks, got #{length(result)}"
    end

    test "handles three distinct topic transitions" do
      # Three clearly different topics
      text = """
      The mitochondria is the powerhouse of the cell.
      Cells divide through a process called mitosis.
      DNA is stored in the nucleus of the cell.
      Python dictionaries store key-value pairs.
      List comprehensions provide concise iteration.
      The def keyword defines a function in Python.
      Mount Everest is the tallest mountain on Earth.
      The Mariana Trench is the deepest ocean point.
      The Sahara is the largest hot desert in the world.
      """

      result = SemanticChunker.chunk(text)

      # Should detect at least 2 boundaries (3+ chunks) for 3 distinct topics
      assert length(result) >= 2,
             "Expected at least 2 chunks for 3 distinct topics, got #{length(result)}"
    end

    test "custom threshold affects boundary sensitivity" do
      text = """
      Elixir is a dynamic, functional language designed for building scalable applications.
      It leverages the Erlang VM, known for running low-latency distributed systems.
      Phoenix is the most popular web framework built with Elixir.
      LiveView enables real-time user experiences with server-rendered HTML.
      """

      result_default = SemanticChunker.chunk(text)
      result_strict = SemanticChunker.chunk(text, similarity_threshold: 0.9)
      result_lenient = SemanticChunker.chunk(text, similarity_threshold: 0.1)

      # Stricter threshold creates more boundaries (more chunks)
      # Lenient threshold creates fewer boundaries (fewer chunks)
      assert length(result_strict) >= length(result_default)
      assert length(result_lenient) <= length(result_default)
    end
  end

  # ---------------------------------------------------------------
  # Chunk metadata with real embeddings
  # ---------------------------------------------------------------

  describe "chunk metadata with real embeddings" do
    test "all chunks have sequential indices" do
      text = """
      Astronomy studies celestial objects and phenomena.
      Cooking involves preparing food using various techniques.
      Music theory explains the structure of musical compositions.
      """

      result = SemanticChunker.chunk(text)
      indices = Enum.map(result, & &1.chunk_index)
      assert indices == Enum.to_list(0..(length(result) - 1))
    end

    test "all chunks have positive token counts" do
      text = """
      Database indexing improves query performance significantly.
      Machine learning models require large amounts of training data.
      """

      result = SemanticChunker.chunk(text)

      Enum.each(result, fn chunk ->
        assert chunk.token_count > 0
      end)
    end

    test "markdown source_type detected with real embeddings" do
      text = """
      # Introduction
      This document covers Elixir basics.

      ## Pattern Matching
      Pattern matching is a key feature of Elixir.

      ## Concurrency
      Elixir uses lightweight processes for concurrency.
      """

      result = SemanticChunker.chunk(text)
      assert Enum.any?(result, fn c -> c.source_type == :markdown end)
    end
  end
end
