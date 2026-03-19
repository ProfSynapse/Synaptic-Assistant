defmodule Assistant.Memory.Activation do
  @moduledoc false

  alias Assistant.Repo

  @spread_rate 0.05
  @neighbor_count 5
  @min_similarity 0.6
  @max_decay_factor 1.5

  @doc """
  Spread activation from retrieved memories to their nearest embedding neighbors.
  This models GNN message-passing: retrieved nodes boost nearby nodes' decay_factor.
  """
  def spread(user_id, retrieved_entries) when is_list(retrieved_entries) do
    retrieved_ids = Enum.map(retrieved_entries, fn
      %{entry: entry} -> entry.id
      %{id: id} -> id
    end)

    retrieved_entries
    |> Enum.each(fn entry ->
      embedding = case entry do
        %{entry: %{embedding: emb}} -> emb
        %{embedding: emb} -> emb
      end

      if embedding do
        spread_from(user_id, embedding, retrieved_ids)
      end
    end)
  end

  def spread(_user_id, _entries), do: :ok

  defp spread_from(user_id, embedding, excluded_ids) do
    embedding_param = Pgvector.new(embedding)
    user_id_bin = Ecto.UUID.dump!(user_id)
    excluded_id_bins = Enum.map(excluded_ids, &Ecto.UUID.dump!/1)

    Repo.query!(
      """
      UPDATE memory_entries
      SET decay_factor = LEAST($1, COALESCE(decay_factor, 1.0) + $2 * (1 - (embedding <=> $3::vector)))
      WHERE id IN (
        SELECT id FROM memory_entries
        WHERE user_id = $4
          AND id != ALL($5)
          AND embedding IS NOT NULL
          AND (1 - (embedding <=> $3::vector)) > $6
        ORDER BY embedding <=> $3::vector
        LIMIT $7
      )
      """,
      [@max_decay_factor, @spread_rate, embedding_param, user_id_bin, excluded_id_bins, @min_similarity, @neighbor_count]
    )
  end
end
