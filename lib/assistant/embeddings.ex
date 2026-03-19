defmodule Assistant.Embeddings do
  @moduledoc false

  @dimensions 384
  # Hard token limit for gte-small is 512. At ~4 chars/token, 2048 chars is the
  # ceiling. Bumblebee silently truncates at sequence_length, but we truncate
  # here as defense-in-depth so the embedding always represents the full input.
  @max_input_chars 2048

  def generate(text) when is_binary(text) and byte_size(text) > 0 do
    if enabled?() do
      %{embedding: tensor} = Nx.Serving.batched_run(__MODULE__, truncate(text))
      {:ok, Nx.to_flat_list(tensor)}
    else
      {:error, :embeddings_disabled}
    end
  end

  def generate(_), do: {:error, :empty_text}

  def generate_batch(texts) when is_list(texts) and length(texts) > 0 do
    if enabled?() do
      # Submit all texts concurrently so Nx.Serving can batch them together.
      # Sequential calls from a single process bypass the batching window.
      tasks = Enum.map(texts, fn text ->
        Task.async(fn -> Nx.Serving.batched_run(__MODULE__, truncate(text)) end)
      end)

      embeddings =
        tasks
        |> Task.await_many(30_000)
        |> Enum.map(fn %{embedding: t} -> Nx.to_flat_list(t) end)

      {:ok, embeddings}
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

  defp truncate(text) when byte_size(text) <= @max_input_chars, do: text
  defp truncate(text), do: String.slice(text, 0, @max_input_chars)
end
