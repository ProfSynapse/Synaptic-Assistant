# lib/assistant/memory/search.ex — Hybrid retrieval for memory entries and
# entity graph queries.
#
# Provides full-text search (PostgreSQL tsvector/plainto_tsquery), tag-based
# filtering, structured filters, and entity graph traversal. Touches
# accessed_at on retrieved entries to feed importance/decay scoring.
#
# Related files:
#   - lib/assistant/memory/store.ex (CRUD persistence layer)
#   - lib/assistant/schemas/memory_entry.ex (search_text tsvector column)
#   - lib/assistant/schemas/memory_entity.ex (entity graph nodes)
#   - lib/assistant/schemas/memory_entity_relation.ex (entity graph edges)
#   - priv/repo/migrations/20260218120000_create_core_tables.exs (GIN indexes)

defmodule Assistant.Memory.Search do
  @moduledoc """
  Hybrid retrieval layer for memory entries and entity graph.

  ## Search Strategies

  - **Full-text search** (`search_memories/2`): Uses PostgreSQL `plainto_tsquery`
    against the `search_text` generated tsvector column. Supports combined FTS +
    tag + category + importance filtering. Touches `accessed_at` on results.
  - **Tag search** (`search_by_tags/2`): Exact tag overlap using `@>` operator
    on the GIN-indexed `tags` array column.
  - **Recency** (`get_recent_entries/2`): Most recent entries by `inserted_at`.
  - **Entity search** (`search_entities/2`): Name fragment ILIKE search on
    `memory_entities`, optionally filtered by entity type.
  - **Relation traversal** (`get_entity_relations/2`): Active relations
    (valid_to IS NULL) for a given entity, both outgoing and incoming.

  Full-text search does NOT use pgvector embeddings (deferred to Phase 3).
  """

  import Ecto.Query

  alias Assistant.Repo
  alias Assistant.Schemas.{MemoryEntity, MemoryEntityRelation, MemoryEntry}

  # ---------------------------------------------------------------------------
  # Full-Text + Hybrid Search
  # ---------------------------------------------------------------------------

  @doc """
  Searches memory entries using PostgreSQL full-text search with optional filters.

  Combines FTS on the `search_text` tsvector column with tag, category, and
  importance filters. Results are ranked by `ts_rank` descending. Touches
  `accessed_at` on all returned entries asynchronously.

  ## Parameters

    * `user_id` - The user whose memories to search (required for scoping).
    * `opts` - Keyword list of search options:
      * `:query` - Text to search for via `plainto_tsquery` (required for FTS)
      * `:tags` - List of tags; entries must contain all specified tags
      * `:category` - Filter by category string
      * `:importance_min` - Minimum importance threshold
      * `:limit` - Max results (default: 10)

  ## Returns

    * `{:ok, [%MemoryEntry{}]}` — matching entries ranked by relevance
  """
  @spec search_memories(binary(), keyword()) :: {:ok, [MemoryEntry.t()]}
  def search_memories(user_id, opts \\ []) do
    query_text = Keyword.get(opts, :query)
    tags = Keyword.get(opts, :tags)
    category = Keyword.get(opts, :category)
    importance_min = Keyword.get(opts, :importance_min)
    limit = Keyword.get(opts, :limit, 10)

    base = from(me in MemoryEntry, where: me.user_id == ^user_id)

    base
    |> maybe_fts(query_text)
    |> maybe_filter_tags(tags)
    |> maybe_filter_category(category)
    |> maybe_filter_importance(importance_min)
    |> apply_ordering(query_text)
    |> limit(^limit)
    |> Repo.all()
    |> touch_accessed_at()
    |> then(&{:ok, &1})
  end

  # ---------------------------------------------------------------------------
  # Tag Search
  # ---------------------------------------------------------------------------

  @doc """
  Searches memory entries by exact tag overlap.

  Uses the PostgreSQL `@>` (contains) operator on the GIN-indexed `tags`
  array column. Returns entries that contain ALL specified tags.

  ## Parameters

    * `user_id` - The user whose memories to search.
    * `tags` - List of tag strings to match.

  ## Returns

    * `{:ok, [%MemoryEntry{}]}` — entries containing all specified tags
  """
  @spec search_by_tags(binary(), [String.t()]) :: {:ok, [MemoryEntry.t()]}
  def search_by_tags(user_id, tags) when is_list(tags) and tags != [] do
    from(me in MemoryEntry,
      where: me.user_id == ^user_id and fragment("? @> ?", me.tags, ^tags),
      order_by: [desc: me.inserted_at]
    )
    |> Repo.all()
    |> touch_accessed_at()
    |> then(&{:ok, &1})
  end

  def search_by_tags(_user_id, _tags), do: {:ok, []}

  # ---------------------------------------------------------------------------
  # Recent Entries
  # ---------------------------------------------------------------------------

  @doc """
  Returns the most recent memory entries for a user.

  ## Parameters

    * `user_id` - The user whose memories to retrieve.
    * `limit` - Max entries to return (default: 10).

  ## Returns

    * `{:ok, [%MemoryEntry{}]}` — most recent entries by `inserted_at`
  """
  @spec get_recent_entries(binary(), non_neg_integer()) :: {:ok, [MemoryEntry.t()]}
  def get_recent_entries(user_id, limit \\ 10) do
    from(me in MemoryEntry,
      where: me.user_id == ^user_id,
      order_by: [desc: me.inserted_at],
      limit: ^limit
    )
    |> Repo.all()
    |> then(&{:ok, &1})
  end

  # ---------------------------------------------------------------------------
  # Entity Search
  # ---------------------------------------------------------------------------

  @doc """
  Searches memory entities by name fragment and/or entity type.

  Uses case-insensitive ILIKE for name matching. All results are scoped
  to the given user.

  ## Parameters

    * `user_id` - The user whose entities to search.
    * `opts` - Keyword list of filters:
      * `:name` - Name fragment for ILIKE search (e.g., "bob" matches "Bobby")
      * `:entity_type` - Filter by type (person, organization, project, concept, location)
      * `:limit` - Max results (default: 20)

  ## Returns

    * `{:ok, [%MemoryEntity{}]}` — matching entities
  """
  @spec search_entities(binary(), keyword()) :: {:ok, [MemoryEntity.t()]}
  def search_entities(user_id, opts \\ []) do
    name = Keyword.get(opts, :name)
    entity_type = Keyword.get(opts, :entity_type)
    limit = Keyword.get(opts, :limit, 20)

    base = from(e in MemoryEntity, where: e.user_id == ^user_id)

    base
    |> maybe_filter_entity_name(name)
    |> maybe_filter_entity_type(entity_type)
    |> order_by([e], asc: e.name)
    |> limit(^limit)
    |> Repo.all()
    |> then(&{:ok, &1})
  end

  # ---------------------------------------------------------------------------
  # Entity Relations
  # ---------------------------------------------------------------------------

  @doc """
  Returns active relations for a given entity (both outgoing and incoming).

  Active relations are those where `valid_to IS NULL`. Preloads source and
  target entities for display.

  ## Parameters

    * `entity_id` - The entity whose relations to retrieve.
    * `opts` - Keyword list of filters:
      * `:relation_type` - Filter by relation type string
      * `:direction` - `:outgoing`, `:incoming`, or `:both` (default: `:both`)

  ## Returns

    * `{:ok, [%MemoryEntityRelation{}]}` — active relations with preloaded entities
  """
  @spec get_entity_relations(binary(), keyword()) :: {:ok, [MemoryEntityRelation.t()]}
  def get_entity_relations(entity_id, opts \\ []) do
    relation_type = Keyword.get(opts, :relation_type)
    direction = Keyword.get(opts, :direction, :both)

    build_relations_query(entity_id, direction)
    |> filter_active_relations()
    |> maybe_filter_relation_type(relation_type)
    |> order_by([r], desc: r.valid_from)
    |> Repo.all()
    |> Repo.preload([:source_entity, :target_entity])
    |> then(&{:ok, &1})
  end

  # ---------------------------------------------------------------------------
  # Private: FTS helpers
  # ---------------------------------------------------------------------------

  defp maybe_fts(query, nil), do: query
  defp maybe_fts(query, ""), do: query

  defp maybe_fts(query, text) do
    from me in query,
      where: fragment("? @@ plainto_tsquery('english', ?)", me.search_text, ^text)
  end

  defp maybe_filter_tags(query, nil), do: query
  defp maybe_filter_tags(query, []), do: query

  defp maybe_filter_tags(query, tags) do
    from me in query, where: fragment("? @> ?", me.tags, ^tags)
  end

  defp maybe_filter_category(query, nil), do: query

  defp maybe_filter_category(query, category) do
    from me in query, where: me.category == ^category
  end

  defp maybe_filter_importance(query, nil), do: query

  defp maybe_filter_importance(query, importance_min) do
    min_decimal =
      case importance_min do
        %Decimal{} = d -> d
        f when is_float(f) -> Decimal.from_float(f)
        i when is_integer(i) -> Decimal.new(i)
      end

    from me in query, where: me.importance >= ^min_decimal
  end

  # When FTS query is provided, rank by ts_rank descending.
  # Otherwise, fall back to inserted_at descending (most recent first).
  defp apply_ordering(query, nil) do
    from me in query, order_by: [desc: me.inserted_at]
  end

  defp apply_ordering(query, "") do
    from me in query, order_by: [desc: me.inserted_at]
  end

  defp apply_ordering(query, text) do
    from me in query,
      order_by: [
        desc: fragment("ts_rank(?, plainto_tsquery('english', ?))", me.search_text, ^text)
      ]
  end

  # ---------------------------------------------------------------------------
  # Private: Entity helpers
  # ---------------------------------------------------------------------------

  defp maybe_filter_entity_name(query, nil), do: query
  defp maybe_filter_entity_name(query, ""), do: query

  defp maybe_filter_entity_name(query, name) do
    pattern = "%#{sanitize_like(name)}%"
    from e in query, where: ilike(e.name, ^pattern)
  end

  defp maybe_filter_entity_type(query, nil), do: query

  defp maybe_filter_entity_type(query, entity_type) do
    from e in query, where: e.entity_type == ^entity_type
  end

  # ---------------------------------------------------------------------------
  # Private: Relation helpers
  # ---------------------------------------------------------------------------

  defp build_relations_query(entity_id, :outgoing) do
    from r in MemoryEntityRelation, where: r.source_entity_id == ^entity_id
  end

  defp build_relations_query(entity_id, :incoming) do
    from r in MemoryEntityRelation, where: r.target_entity_id == ^entity_id
  end

  defp build_relations_query(entity_id, _both) do
    from r in MemoryEntityRelation,
      where: r.source_entity_id == ^entity_id or r.target_entity_id == ^entity_id
  end

  defp filter_active_relations(query) do
    from r in query, where: is_nil(r.valid_to)
  end

  defp maybe_filter_relation_type(query, nil), do: query

  defp maybe_filter_relation_type(query, relation_type) do
    from r in query, where: r.relation_type == ^relation_type
  end

  # ---------------------------------------------------------------------------
  # Private: accessed_at tracking
  # ---------------------------------------------------------------------------

  # Touches accessed_at on all returned entries. Runs as a bulk update
  # to avoid N+1 queries. Returns the original entries unchanged (the
  # caller gets the pre-touch data, which is fine for display).
  defp touch_accessed_at([]), do: []

  defp touch_accessed_at(entries) do
    ids = Enum.map(entries, & &1.id)
    now = DateTime.utc_now()

    from(me in MemoryEntry, where: me.id in ^ids)
    |> Repo.update_all(set: [accessed_at: now])

    entries
  end

  # Sanitizes user input for ILIKE to prevent wildcard injection.
  # Escapes %, _, and \ characters.
  defp sanitize_like(input) do
    input
    |> String.replace("\\", "\\\\")
    |> String.replace("%", "\\%")
    |> String.replace("_", "\\_")
  end
end
