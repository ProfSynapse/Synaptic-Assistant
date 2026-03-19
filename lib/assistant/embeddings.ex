defmodule Assistant.Embeddings do
  @moduledoc false

  @dimensions 384

  def generate(text) when is_binary(text) and byte_size(text) > 0 do
    if enabled?() do
      %{embedding: tensor} = Nx.Serving.batched_run(__MODULE__, text)
      {:ok, Nx.to_flat_list(tensor)}
    else
      {:error, :embeddings_disabled}
    end
  end

  def generate(_), do: {:error, :empty_text}

  def generate_batch(texts) when is_list(texts) and length(texts) > 0 do
    if enabled?() do
      results =
        texts
        |> Enum.map(fn text -> Nx.Serving.batched_run(__MODULE__, text) end)

      {:ok, Enum.map(results, fn %{embedding: t} -> Nx.to_flat_list(t) end)}
    else
      {:error, :embeddings_disabled}
    end
  end

  def generate_batch(_), do: {:error, :empty_batch}

  def dimensions, do: @dimensions

  def enabled? do
    Application.get_env(:assistant, :embeddings, [])
    |> Keyword.get(:enabled, false)
  end
end
