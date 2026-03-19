defmodule Assistant.Embeddings.SemanticChunker do
  @moduledoc false
  @behaviour Arcana.Chunker

  @similarity_threshold 0.5
  @max_tokens 450
  @min_tokens 50
  @approx_chars_per_token 4

  @impl true
  def chunk(text, opts \\ []) do
    threshold = Keyword.get(opts, :similarity_threshold, @similarity_threshold)

    sentences = split_sentences(text)

    case sentences do
      [] ->
        []

      [single] ->
        [build_chunk(single, 0, text)]

      sentences ->
        sentences
        |> embed_sentences()
        |> detect_boundaries(threshold)
        |> group_into_chunks(sentences)
        |> enforce_size_limits()
        |> add_metadata(text)
    end
  end

  # Split on markdown headers (always boundaries) then on sentence-ending punctuation
  defp split_sentences(text) do
    text
    |> String.split(~r/(?=^\#{1,6}\s)/m)
    |> Enum.flat_map(&split_block_sentences/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp split_block_sentences(block) do
    String.split(block, ~r/(?<=[.!?])\s+|\n\n+/)
  end

  defp embed_sentences(sentences) do
    case Assistant.Embeddings.generate_batch(sentences) do
      {:ok, embeddings} -> Enum.zip(sentences, embeddings)
      {:error, _} -> Enum.map(sentences, &{&1, nil})
    end
  end

  defp detect_boundaries(sentence_embeddings, threshold) do
    similarities =
      sentence_embeddings
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.with_index()
      |> Enum.map(fn {[{_s1, e1}, {_s2, e2}], idx} ->
        sim = if e1 && e2, do: cosine_similarity(e1, e2), else: 1.0
        {idx, sim}
      end)

    # Boundary after index where similarity drops below threshold
    boundaries =
      similarities
      |> Enum.filter(fn {_idx, sim} -> sim < threshold end)
      |> Enum.map(fn {idx, _sim} -> idx + 1 end)

    {boundaries, similarities}
  end

  defp cosine_similarity(a, b) do
    # Vectors are L2-normalized by gte-small, so dot product = cosine
    Enum.zip_reduce(a, b, 0.0, fn x, y, acc -> acc + x * y end)
  end

  defp group_into_chunks({boundaries, _similarities}, sentences) do
    # Split sentence list at boundary indices
    split_points = [0 | boundaries] ++ [length(sentences)]

    split_points
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.map(fn [start, stop] ->
      Enum.slice(sentences, start..(stop - 1))
      |> Enum.join(" ")
    end)
    |> Enum.reject(&(&1 == ""))
  end

  defp enforce_size_limits(chunks) do
    chunks
    |> Enum.flat_map(&maybe_split_large/1)
    |> merge_small([])
  end

  defp maybe_split_large(chunk) do
    token_count = estimate_tokens(chunk)

    if token_count > @max_tokens do
      # Split roughly in half at a sentence boundary
      sentences = String.split(chunk, ~r/(?<=[.!?])\s+/)
      mid = div(length(sentences), 2)
      {first, second} = Enum.split(sentences, max(mid, 1))

      [Enum.join(first, " "), Enum.join(second, " ")]
      |> Enum.reject(&(&1 == ""))
      |> Enum.flat_map(&maybe_split_large/1)
    else
      [chunk]
    end
  end

  defp merge_small([], acc), do: Enum.reverse(acc)

  defp merge_small([chunk | rest], []) do
    merge_small(rest, [chunk])
  end

  defp merge_small([chunk | rest], [prev | acc]) do
    merged = prev <> " " <> chunk

    if estimate_tokens(chunk) < @min_tokens and estimate_tokens(merged) <= @max_tokens do
      # Merge with previous chunk only if combined size stays within limit
      merge_small(rest, [merged | acc])
    else
      merge_small(rest, [chunk, prev | acc])
    end
  end

  defp add_metadata(chunks, original_text) do
    header_path = extract_header_path(original_text)

    chunks
    |> Enum.with_index()
    |> Enum.map(fn {text, idx} ->
      %{
        text: text,
        chunk_index: idx,
        token_count: estimate_tokens(text),
        header_path: header_path,
        source_type: if(String.contains?(original_text, "\n#"), do: :markdown, else: :plain)
      }
    end)
  end

  defp extract_header_path(text) do
    text
    |> String.split("\n")
    |> Enum.filter(&String.match?(&1, ~r/^\#{1,6}\s/))
    |> Enum.map(&String.replace(&1, ~r/^#+\s*/, ""))
    |> Enum.join(" > ")
    |> case do
      "" -> nil
      path -> path
    end
  end

  defp estimate_tokens(text) do
    div(byte_size(text), @approx_chars_per_token)
  end

  defp build_chunk(text, index, _original) do
    %{
      text: text,
      chunk_index: index,
      token_count: estimate_tokens(text),
      header_path: nil,
      source_type: :plain
    }
  end
end
