defmodule Assistant.Embeddings.ArcanaEmbedder do
  @moduledoc false
  @behaviour Arcana.Embedder

  @impl true
  def embed(text, _opts) do
    Assistant.Embeddings.generate(text)
  end

  @impl true
  def embed_batch(texts, _opts) do
    Assistant.Embeddings.generate_batch(texts)
  end

  @impl true
  def dimensions(_opts), do: 384
end
