defmodule Assistant.EmbeddingsTest do
  use ExUnit.Case, async: false

  alias Assistant.Embeddings

  setup do
    original = Application.get_env(:assistant, :embeddings, [])
    on_exit(fn -> Application.put_env(:assistant, :embeddings, original) end)
    :ok
  end

  describe "module exports" do
    test "exports expected functions" do
      assert function_exported?(Embeddings, :generate, 1)
      assert function_exported?(Embeddings, :generate_batch, 1)
      assert function_exported?(Embeddings, :dimensions, 0)
      assert function_exported?(Embeddings, :enabled?, 0)
    end
  end

  describe "dimensions/0" do
    test "returns 384" do
      assert Embeddings.dimensions() == 384
    end
  end

  describe "enabled?/0" do
    test "returns false when embeddings disabled in config" do
      Application.put_env(:assistant, :embeddings, enabled: false)
      refute Embeddings.enabled?()
    end

    test "returns true when embeddings enabled in config" do
      Application.put_env(:assistant, :embeddings, enabled: true)
      assert Embeddings.enabled?()
    end

    test "returns false when config key is missing" do
      Application.delete_env(:assistant, :embeddings)
      refute Embeddings.enabled?()
    end
  end

  describe "generate/1" do
    test "returns error for empty string" do
      assert {:error, :empty_text} = Embeddings.generate("")
    end

    test "returns error for nil" do
      assert {:error, :empty_text} = Embeddings.generate(nil)
    end

    test "returns error for non-binary input" do
      assert {:error, :empty_text} = Embeddings.generate(123)
    end

    test "returns embeddings_disabled when disabled" do
      Application.put_env(:assistant, :embeddings, enabled: false)
      assert {:error, :embeddings_disabled} = Embeddings.generate("valid text")
    end
  end

  describe "generate_batch/1" do
    test "returns error for empty list" do
      assert {:error, :empty_batch} = Embeddings.generate_batch([])
    end

    test "returns error for non-list input" do
      assert {:error, :empty_batch} = Embeddings.generate_batch("not a list")
    end

    test "returns embeddings_disabled when disabled" do
      Application.put_env(:assistant, :embeddings, enabled: false)
      assert {:error, :embeddings_disabled} = Embeddings.generate_batch(["text"])
    end
  end
end
