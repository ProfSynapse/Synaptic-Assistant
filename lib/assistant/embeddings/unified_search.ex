defmodule Assistant.Embeddings.UnifiedSearch do
  @moduledoc false

  import Ecto.Query
  alias Assistant.Repo
  alias Assistant.Schemas.DocumentFolder
  alias Assistant.Embeddings
  alias Assistant.Embeddings.DocumentActivation

  @rrf_k 60

  @doc """
  Search across memories and documents in parallel, merge via RRF.
  Falls back to memory-only FTS when embeddings are disabled.
  """
  def search(user_id, query, opts \\ []) do
    limit = Keyword.get(opts, :limit, 10)

    if Embeddings.enabled?() do
      # Fan out in parallel
      memory_task = Task.async(fn ->
        search_memories(user_id, query, limit: limit)
      end)

      doc_task = Task.async(fn ->
        search_documents(user_id, query, limit: limit * 2)
      end)

      memories = Task.await(memory_task, 5_000)
      docs = Task.await(doc_task, 5_000)

      merge_rrf(memories, docs, limit)
    else
      # Fallback to FTS-only memory search
      search_memories_fts(user_id, query, limit: limit)
    end
  end

  @doc """
  Search documents with folder activation boost applied.
  Overfetches then re-ranks with folder boost, triggers spreading activation.
  """
  def search_documents(user_id, query_text, opts \\ []) do
    limit = Keyword.get(opts, :limit, 10)

    # Step 1: Arcana semantic + FTS search
    arcana_results = arcana_search(user_id, query_text, limit * 2)

    # Step 2: Load folder activation boosts
    folder_ids =
      arcana_results
      |> Enum.map(fn r ->
        case r do
          %{metadata: %{"parent_folder_id" => fid}} -> fid
          _ -> nil
        end
      end)
      |> Enum.uniq()
      |> Enum.reject(&is_nil/1)

    folder_boosts =
      if folder_ids != [] do
        from(df in DocumentFolder,
          where: df.drive_folder_id in ^folder_ids,
          select: {df.drive_folder_id, df.activation_boost}
        )
        |> Repo.all()
        |> Map.new()
      else
        %{}
      end

    # Step 3: Re-rank with folder boost
    results =
      arcana_results
      |> Enum.map(fn result ->
        folder_id =
          case result do
            %{metadata: %{"parent_folder_id" => fid}} -> fid
            _ -> nil
          end

        boost = Map.get(folder_boosts, folder_id, 1.0)
        Map.update!(result, :score, &(&1 * boost))
      end)
      |> Enum.sort_by(& &1.score, :desc)
      |> Enum.take(limit)

    # Trigger spreading activation post-retrieval
    Task.start(fn -> DocumentActivation.spread(results) end)

    results
  end

  @doc """
  Search folder embeddings directly for topic-level matches.
  Returns folders ranked by similarity to the query.
  """
  def search_folders(user_id, query_text, opts \\ []) do
    limit = Keyword.get(opts, :limit, 3)

    case Embeddings.generate(query_text) do
      {:ok, query_embedding} ->
        from(df in DocumentFolder,
          where: df.user_id == ^user_id and not is_nil(df.embedding),
          order_by: fragment("embedding <=> ?::vector", ^query_embedding),
          limit: ^limit,
          select: %{
            folder: df,
            similarity: fragment("1 - (embedding <=> ?::vector)", ^query_embedding)
          }
        )
        |> Repo.all()

      {:error, _} ->
        []
    end
  end

  # Private helpers

  defp search_memories(user_id, query, opts) do
    # Delegate to Memory.Search.hybrid_search when available
    # For now, use FTS fallback
    search_memories_fts(user_id, query, opts)
  end

  defp search_memories_fts(user_id, query, opts) do
    limit = Keyword.get(opts, :limit, 10)

    # Delegate to existing Memory.Search FTS
    case Assistant.Memory.Search.search(user_id, query, limit: limit) do
      {:ok, results} ->
        results
        |> Enum.with_index()
        |> Enum.map(fn {entry, idx} ->
          %{
            type: :memory,
            id: entry.id,
            content: entry.content,
            score: 1.0 / (idx + 1),
            metadata: %{
              "category" => entry.category,
              "importance" => entry.importance
            }
          }
        end)

      _ ->
        []
    end
  end

  defp arcana_search(_user_id, _query_text, _limit) do
    # Arcana.search(query_text,
    #   collection: "user_documents",
    #   mode: :hybrid,
    #   semantic_weight: 0.7,
    #   fulltext_weight: 0.3,
    #   limit: limit,
    #   where: [metadata: %{user_id: to_string(user_id)}]
    # )
    # Stubbed until Arcana is installed and collections created
    []
  end

  @doc """
  Reciprocal Rank Fusion: merge two ranked lists with equal weight.
  RRF(d) = sum(1 / (k + rank_i(d))) for each list i where d appears.
  """
  def merge_rrf(list_a, list_b, limit) do
    scored_a =
      list_a
      |> Enum.with_index(1)
      |> Enum.map(fn {item, rank} ->
        id = item_id(item)
        {id, item, 1.0 / (@rrf_k + rank)}
      end)

    scored_b =
      list_b
      |> Enum.with_index(1)
      |> Enum.map(fn {item, rank} ->
        id = item_id(item)
        {id, item, 1.0 / (@rrf_k + rank)}
      end)

    # Merge scores for items appearing in both lists
    all_items =
      (scored_a ++ scored_b)
      |> Enum.group_by(fn {id, _item, _score} -> id end)
      |> Enum.map(fn {_id, entries} ->
        {_id, item, _score} = hd(entries)
        total_score = entries |> Enum.map(fn {_, _, s} -> s end) |> Enum.sum()
        %{item | score: total_score}
      end)
      |> Enum.sort_by(& &1.score, :desc)
      |> Enum.take(limit)

    all_items
  end

  defp item_id(%{id: id}), do: id
  defp item_id(%{entry: %{id: id}}), do: id
  defp item_id(item), do: :erlang.phash2(item)
end
