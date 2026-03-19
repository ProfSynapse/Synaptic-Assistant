defmodule Assistant.Embeddings.ArcanaEmbedderTest do
  use ExUnit.Case, async: true

  alias Assistant.Embeddings.ArcanaEmbedder

  describe "module compilation" do
    test "module is loaded" do
      assert Code.ensure_loaded?(ArcanaEmbedder)
    end

    test "exports Arcana.Embedder behaviour callbacks" do
      assert function_exported?(ArcanaEmbedder, :embed, 2)
      assert function_exported?(ArcanaEmbedder, :embed_batch, 2)
      assert function_exported?(ArcanaEmbedder, :dimensions, 1)
    end
  end

  describe "dimensions/1" do
    test "returns 384 regardless of opts" do
      assert ArcanaEmbedder.dimensions([]) == 384
      assert ArcanaEmbedder.dimensions(model: "test") == 384
    end
  end

  describe "embed/2 delegation" do
    test "returns embeddings_disabled when embeddings are off" do
      assert {:error, :embeddings_disabled} = ArcanaEmbedder.embed("test text", [])
    end

    test "returns error for empty text" do
      assert {:error, :empty_text} = ArcanaEmbedder.embed("", [])
    end
  end

  describe "embed_batch/2 delegation" do
    test "returns embeddings_disabled when embeddings are off" do
      assert {:error, :embeddings_disabled} = ArcanaEmbedder.embed_batch(["text"], [])
    end

    test "returns error for empty batch" do
      assert {:error, :empty_batch} = ArcanaEmbedder.embed_batch([], [])
    end
  end
end
