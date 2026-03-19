defmodule Assistant.Memory.Activation do
  @moduledoc false

  import Ecto.Query
  alias Assistant.Repo
  alias Assistant.Schemas.MemoryEntry

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
    from(me in MemoryEntry,
      where: me.user_id == ^user_id
        and me.id not in ^excluded_ids
        and not is_nil(me.embedding)
        and fragment("1 - (embedding <=> ?::vector)", ^embedding) > ^@min_similarity,
      order_by: fragment("embedding <=> ?::vector", ^embedding),
      limit: ^@neighbor_count
    )
    |> Repo.update_all(
      set: [
        decay_factor: fragment(
          "LEAST(?, COALESCE(decay_factor, 1.0) + ? * (1 - (embedding <=> ?::vector)))",
          ^@max_decay_factor, ^@spread_rate, ^embedding
        )
      ]
    )
  end
end
