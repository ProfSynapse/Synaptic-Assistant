defmodule Assistant.MemoryGraph do
  @moduledoc """
  Builds graph-ready memory/entity/transcript data for the settings UI.
  """

  import Ecto.Query

  alias Assistant.Accounts.Scope
  alias Assistant.Repo

  alias Assistant.Schemas.{
    Conversation,
    MemoryEntity,
    MemoryEntityMention,
    MemoryEntityRelation,
    MemoryEntry
  }

  @default_entity_limit 28
  @default_memory_limit 28
  @default_transcript_limit 18
  @default_expand_limit 42

  @type graph_data :: %{nodes: [map()], links: [map()]}

  @spec get_initial_graph(map() | nil, map()) :: graph_data()
  def get_initial_graph(%Scope{settings_user: %{user_id: user_id}}, filters)
      when is_binary(user_id) do
    opts = normalize_filters(filters)
    flags = include_flags(opts.type)

    entities =
      if flags.entities do
        fetch_entities(user_id, opts, @default_entity_limit)
      else
        []
      end

    memories =
      if flags.memories do
        fetch_memories(user_id, opts, @default_memory_limit)
      else
        []
      end

    transcripts =
      if flags.transcripts do
        fetch_transcripts(user_id, memories, opts, @default_transcript_limit)
      else
        []
      end

    to_graph(entities, memories, transcripts, opts, flags)
  end

  def get_initial_graph(_, _), do: empty_graph()

  @spec expand_node(map() | nil, String.t(), map()) :: graph_data()
  def expand_node(%Scope{settings_user: %{user_id: user_id}}, node_id, filters)
      when is_binary(user_id) and is_binary(node_id) do
    opts = normalize_filters(filters)
    flags = include_flags(opts.type)

    case parse_node_id(node_id) do
      {:entity, entity_id} -> expand_from_entity(user_id, entity_id, opts, flags)
      {:memory, memory_id} -> expand_from_memory(user_id, memory_id, opts, flags)
      {:transcript, transcript_id} -> expand_from_transcript(user_id, transcript_id, opts, flags)
      :error -> empty_graph()
    end
  end

  def expand_node(_, _, _), do: empty_graph()

  defp expand_from_entity(user_id, entity_id, opts, flags) do
    relation_rows =
      fetch_relations_touching_entities(user_id, [entity_id], opts.since, @default_expand_limit)

    entity_ids =
      relation_rows
      |> Enum.flat_map(fn row -> [row.source_entity_id, row.target_entity_id] end)
      |> Kernel.++([entity_id])
      |> Enum.uniq()

    entities =
      if flags.entities do
        fetch_entities_by_ids(user_id, entity_ids)
      else
        []
      end

    mention_rows =
      if flags.entities and flags.memories do
        fetch_mentions_for_entities(user_id, entity_ids, opts.since, @default_expand_limit)
      else
        []
      end

    memory_ids = mention_rows |> Enum.map(& &1.memory_entry_id) |> Enum.uniq()

    memories =
      if flags.memories do
        fetch_memories_by_ids(user_id, memory_ids, opts.since)
      else
        []
      end

    transcripts =
      if flags.transcripts do
        memories
        |> Enum.map(& &1.source_conversation_id)
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()
        |> fetch_transcripts_by_ids(user_id)
      else
        []
      end

    to_graph(entities, memories, transcripts, opts, flags, relation_rows, mention_rows)
  end

  defp expand_from_memory(user_id, memory_id, opts, flags) do
    memories =
      if flags.memories do
        fetch_memories_by_ids(user_id, [memory_id], opts.since)
      else
        []
      end

    mention_rows =
      if flags.entities and flags.memories do
        fetch_mentions_for_memories(user_id, [memory_id], opts.since, @default_expand_limit)
      else
        []
      end

    entity_ids = mention_rows |> Enum.map(& &1.entity_id) |> Enum.uniq()

    entities =
      if flags.entities do
        fetch_entities_by_ids(user_id, entity_ids)
      else
        []
      end

    relation_rows =
      if flags.entities do
        fetch_relations_between_entities(user_id, entity_ids, opts.since, @default_expand_limit)
      else
        []
      end

    transcripts =
      if flags.transcripts do
        memories
        |> Enum.map(& &1.source_conversation_id)
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()
        |> fetch_transcripts_by_ids(user_id)
      else
        []
      end

    to_graph(entities, memories, transcripts, opts, flags, relation_rows, mention_rows)
  end

  defp expand_from_transcript(user_id, transcript_id, opts, flags) do
    transcripts =
      if flags.transcripts do
        fetch_transcripts_by_ids(user_id, [transcript_id])
      else
        []
      end

    memory_ids =
      if flags.memories do
        fetch_memory_ids_for_transcript(user_id, transcript_id, opts.since, @default_expand_limit)
      else
        []
      end

    memories =
      if flags.memories do
        fetch_memories_by_ids(user_id, memory_ids, opts.since)
      else
        []
      end

    mention_rows =
      if flags.entities and flags.memories do
        fetch_mentions_for_memories(user_id, memory_ids, opts.since, @default_expand_limit)
      else
        []
      end

    entity_ids = mention_rows |> Enum.map(& &1.entity_id) |> Enum.uniq()

    entities =
      if flags.entities do
        fetch_entities_by_ids(user_id, entity_ids)
      else
        []
      end

    relation_rows =
      if flags.entities do
        fetch_relations_between_entities(user_id, entity_ids, opts.since, @default_expand_limit)
      else
        []
      end

    to_graph(entities, memories, transcripts, opts, flags, relation_rows, mention_rows)
  end

  defp to_graph(
         entities,
         memories,
         transcripts,
         opts,
         flags,
         relation_rows \\ nil,
         mention_rows \\ nil
       ) do
    entity_ids = Enum.map(entities, & &1.id)
    memory_ids = Enum.map(memories, & &1.id)

    relation_rows =
      relation_rows ||
        if flags.entities do
          fetch_relations_between_entities(
            user_id_for_entities(entities),
            entity_ids,
            opts.since,
            90
          )
        else
          []
        end

    mention_rows =
      mention_rows ||
        if flags.entities and flags.memories do
          fetch_mentions_between(
            user_id_for_memories(memories),
            entity_ids,
            memory_ids,
            opts.since,
            120
          )
        else
          []
        end

    nodes =
      entities
      |> Enum.map(&entity_node/1)
      |> Kernel.++(Enum.map(memories, &memory_node/1))
      |> Kernel.++(Enum.map(transcripts, &transcript_node/1))
      |> unique_by_id()

    links =
      relation_rows
      |> Enum.map(&relation_link/1)
      |> Kernel.++(Enum.map(mention_rows, &mention_link/1))
      |> Kernel.++(source_links(memories, transcripts))
      |> unique_by_id()

    %{nodes: nodes, links: links}
  end

  defp user_id_for_entities([entity | _]), do: entity.user_id
  defp user_id_for_entities([]), do: nil

  defp user_id_for_memories([memory | _]), do: memory.user_id
  defp user_id_for_memories([]), do: nil

  defp fetch_entities(user_id, opts, limit) do
    from(e in MemoryEntity,
      where: e.user_id == ^user_id,
      order_by: [desc: e.inserted_at],
      limit: ^limit
    )
    |> maybe_filter_entity_query(opts.query)
    |> maybe_filter_entity_since(opts.since)
    |> Repo.all()
  end

  defp fetch_entities_by_ids(_user_id, []), do: []

  defp fetch_entities_by_ids(user_id, ids) do
    from(e in MemoryEntity,
      where: e.user_id == ^user_id and e.id in ^ids
    )
    |> Repo.all()
  end

  defp fetch_memories(user_id, opts, limit) do
    from(m in MemoryEntry,
      where: m.user_id == ^user_id,
      order_by: [desc: m.inserted_at],
      limit: ^limit
    )
    |> maybe_filter_memory_query(opts.query)
    |> maybe_filter_memory_since(opts.since)
    |> Repo.all()
  end

  defp fetch_memories_by_ids(_user_id, [], _since), do: []

  defp fetch_memories_by_ids(user_id, ids, since) do
    from(m in MemoryEntry,
      where: m.user_id == ^user_id and m.id in ^ids,
      order_by: [desc: m.inserted_at]
    )
    |> maybe_filter_memory_since(since)
    |> Repo.all()
  end

  defp fetch_transcripts(user_id, memories, opts, limit) do
    memory_conversation_ids =
      memories
      |> Enum.map(& &1.source_conversation_id)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    primary =
      from(c in Conversation,
        where: c.user_id == ^user_id,
        order_by: [desc: fragment("COALESCE(?, ?)", c.last_active_at, c.inserted_at)],
        limit: ^limit
      )
      |> maybe_filter_transcript_query(opts.query)
      |> maybe_filter_transcript_since(opts.since)
      |> Repo.all()

    if memory_conversation_ids == [] do
      primary
    else
      extra = fetch_transcripts_by_ids(user_id, memory_conversation_ids)
      unique_by_id(primary ++ extra)
    end
  end

  defp fetch_transcripts_by_ids(_user_id, []), do: []

  defp fetch_transcripts_by_ids(user_id, ids) do
    from(c in Conversation,
      where: c.user_id == ^user_id and c.id in ^ids
    )
    |> Repo.all()
  end

  defp fetch_memory_ids_for_transcript(user_id, transcript_id, since, limit) do
    from(m in MemoryEntry,
      where: m.user_id == ^user_id and m.source_conversation_id == ^transcript_id,
      order_by: [desc: m.inserted_at],
      limit: ^limit,
      select: m.id
    )
    |> maybe_filter_memory_id_since(since)
    |> Repo.all()
  end

  defp fetch_relations_touching_entities(user_id, entity_ids, since, limit) do
    from(r in MemoryEntityRelation,
      join: source in MemoryEntity,
      on: source.id == r.source_entity_id,
      join: target in MemoryEntity,
      on: target.id == r.target_entity_id,
      where:
        source.user_id == ^user_id and
          target.user_id == ^user_id and
          is_nil(r.valid_to) and
          (r.source_entity_id in ^entity_ids or r.target_entity_id in ^entity_ids),
      order_by: [desc: r.inserted_at],
      limit: ^limit,
      select: %{
        id: r.id,
        source_entity_id: r.source_entity_id,
        target_entity_id: r.target_entity_id,
        relation_type: r.relation_type
      }
    )
    |> maybe_filter_relation_since(since)
    |> Repo.all()
  end

  defp fetch_relations_between_entities(_user_id, [], _since, _limit), do: []
  defp fetch_relations_between_entities(nil, _entity_ids, _since, _limit), do: []

  defp fetch_relations_between_entities(user_id, entity_ids, since, limit) do
    from(r in MemoryEntityRelation,
      join: source in MemoryEntity,
      on: source.id == r.source_entity_id,
      join: target in MemoryEntity,
      on: target.id == r.target_entity_id,
      where:
        source.user_id == ^user_id and
          target.user_id == ^user_id and
          is_nil(r.valid_to) and
          r.source_entity_id in ^entity_ids and
          r.target_entity_id in ^entity_ids,
      order_by: [desc: r.inserted_at],
      limit: ^limit,
      select: %{
        id: r.id,
        source_entity_id: r.source_entity_id,
        target_entity_id: r.target_entity_id,
        relation_type: r.relation_type
      }
    )
    |> maybe_filter_relation_since(since)
    |> Repo.all()
  end

  defp fetch_mentions_between(_user_id, [], _memory_ids, _since, _limit), do: []
  defp fetch_mentions_between(_user_id, _entity_ids, [], _since, _limit), do: []
  defp fetch_mentions_between(nil, _entity_ids, _memory_ids, _since, _limit), do: []

  defp fetch_mentions_between(user_id, entity_ids, memory_ids, since, limit) do
    from(em in MemoryEntityMention,
      join: m in MemoryEntry,
      on: m.id == em.memory_entry_id,
      where:
        m.user_id == ^user_id and
          em.entity_id in ^entity_ids and
          em.memory_entry_id in ^memory_ids,
      order_by: [desc: em.inserted_at],
      limit: ^limit,
      select: %{id: em.id, entity_id: em.entity_id, memory_entry_id: em.memory_entry_id}
    )
    |> maybe_filter_mention_since(since)
    |> Repo.all()
  end

  defp fetch_mentions_for_entities(_user_id, [], _since, _limit), do: []

  defp fetch_mentions_for_entities(user_id, entity_ids, since, limit) do
    from(em in MemoryEntityMention,
      join: m in MemoryEntry,
      on: m.id == em.memory_entry_id,
      where: m.user_id == ^user_id and em.entity_id in ^entity_ids,
      order_by: [desc: m.inserted_at],
      limit: ^limit,
      select: %{id: em.id, entity_id: em.entity_id, memory_entry_id: em.memory_entry_id}
    )
    |> maybe_filter_mention_since(since)
    |> Repo.all()
  end

  defp fetch_mentions_for_memories(_user_id, [], _since, _limit), do: []

  defp fetch_mentions_for_memories(user_id, memory_ids, since, limit) do
    from(em in MemoryEntityMention,
      join: m in MemoryEntry,
      on: m.id == em.memory_entry_id,
      where: m.user_id == ^user_id and em.memory_entry_id in ^memory_ids,
      order_by: [desc: em.inserted_at],
      limit: ^limit,
      select: %{id: em.id, entity_id: em.entity_id, memory_entry_id: em.memory_entry_id}
    )
    |> maybe_filter_mention_since(since)
    |> Repo.all()
  end

  defp source_links(memories, transcripts) do
    transcript_ids = transcripts |> Enum.map(& &1.id) |> MapSet.new()

    memories
    |> Enum.reduce([], fn memory, acc ->
      conversation_id = memory.source_conversation_id

      if is_binary(conversation_id) and MapSet.member?(transcript_ids, conversation_id) do
        [
          %{
            id: "source:#{memory.id}:#{conversation_id}",
            source: "memory:#{memory.id}",
            target: "transcript:#{conversation_id}",
            label: "source",
            kind: "source",
            color: "rgba(41, 171, 226, 0.35)",
            directional: true
          }
          | acc
        ]
      else
        acc
      end
    end)
  end

  defp relation_link(relation) do
    %{
      id: "relation:#{relation.id}",
      source: "entity:#{relation.source_entity_id}",
      target: "entity:#{relation.target_entity_id}",
      label: relation.relation_type,
      kind: "relation",
      color: "rgba(147, 39, 143, 0.5)",
      directional: true
    }
  end

  defp mention_link(mention) do
    %{
      id: "mention:#{mention.id}",
      source: "memory:#{mention.memory_entry_id}",
      target: "entity:#{mention.entity_id}",
      label: "mentioned",
      kind: "mention",
      color: "rgba(247, 147, 30, 0.42)",
      directional: false
    }
  end

  defp entity_node(entity) do
    %{
      id: "entity:#{entity.id}",
      kind: "entity",
      label: entity.name,
      entity_type: entity.entity_type,
      color: entity_color(entity.entity_type),
      val: 8
    }
  end

  defp memory_node(memory) do
    %{
      id: "memory:#{memory.id}",
      kind: "memory",
      label: truncate_text(memory.content, 84),
      category: memory.category,
      color: "#29abe2",
      val: 6
    }
  end

  defp transcript_node(transcript) do
    channel =
      transcript.channel
      |> to_string()
      |> String.trim()
      |> case do
        "" -> "transcript"
        value -> value
      end
      |> String.capitalize()

    %{
      id: "transcript:#{transcript.id}",
      kind: "transcript",
      label: "#{channel} #{short_id(transcript.id)}",
      color: "#00a99d",
      val: 7
    }
  end

  defp include_flags("entities"), do: %{entities: true, memories: false, transcripts: false}
  defp include_flags("memories"), do: %{entities: true, memories: true, transcripts: false}
  defp include_flags("transcripts"), do: %{entities: false, memories: true, transcripts: true}
  defp include_flags(_), do: %{entities: true, memories: true, transcripts: true}

  defp normalize_filters(filters) when is_map(filters) do
    %{
      query: filters |> Map.get("query", "") |> to_string() |> String.trim(),
      type: filters |> Map.get("type", "all") |> to_string() |> String.trim(),
      since:
        timeframe_since(filters |> Map.get("timeframe", "30d") |> to_string() |> String.trim())
    }
  end

  defp normalize_filters(_), do: %{query: "", type: "all", since: timeframe_since("30d")}

  defp timeframe_since("24h"), do: DateTime.add(DateTime.utc_now(), -24 * 60 * 60, :second)
  defp timeframe_since("7d"), do: DateTime.add(DateTime.utc_now(), -7 * 24 * 60 * 60, :second)
  defp timeframe_since("30d"), do: DateTime.add(DateTime.utc_now(), -30 * 24 * 60 * 60, :second)
  defp timeframe_since("90d"), do: DateTime.add(DateTime.utc_now(), -90 * 24 * 60 * 60, :second)
  defp timeframe_since(_), do: nil

  defp parse_node_id(node_id) do
    case String.split(node_id, ":", parts: 2) do
      ["entity", id] when id != "" -> {:entity, id}
      ["memory", id] when id != "" -> {:memory, id}
      ["transcript", id] when id != "" -> {:transcript, id}
      _ -> :error
    end
  end

  defp maybe_filter_entity_query(queryable, ""), do: queryable

  defp maybe_filter_entity_query(queryable, query) do
    pattern = "%#{query}%"
    where(queryable, [e], ilike(e.name, ^pattern))
  end

  defp maybe_filter_memory_query(queryable, ""), do: queryable

  defp maybe_filter_memory_query(queryable, query) do
    pattern = "%#{query}%"
    where(queryable, [m], ilike(m.content, ^pattern))
  end

  defp maybe_filter_transcript_query(queryable, ""), do: queryable

  defp maybe_filter_transcript_query(queryable, query) do
    pattern = "%#{query}%"

    where(
      queryable,
      [c],
      fragment("CAST(? AS text) ILIKE ?", c.id, ^pattern) or ilike(c.channel, ^pattern)
    )
  end

  defp maybe_filter_entity_since(queryable, nil), do: queryable

  defp maybe_filter_entity_since(queryable, since),
    do: where(queryable, [e], e.inserted_at >= ^since)

  defp maybe_filter_memory_since(queryable, nil), do: queryable

  defp maybe_filter_memory_since(queryable, since),
    do: where(queryable, [m], m.inserted_at >= ^since)

  defp maybe_filter_memory_id_since(queryable, nil), do: queryable

  defp maybe_filter_memory_id_since(queryable, since),
    do: where(queryable, [m], m.inserted_at >= ^since)

  defp maybe_filter_transcript_since(queryable, nil), do: queryable

  defp maybe_filter_transcript_since(queryable, since) do
    where(
      queryable,
      [c],
      fragment("COALESCE(?, ?) >= ?", c.last_active_at, c.inserted_at, ^since)
    )
  end

  defp maybe_filter_relation_since(queryable, nil), do: queryable

  defp maybe_filter_relation_since(queryable, since) do
    where(queryable, [r], r.inserted_at >= ^since)
  end

  defp maybe_filter_mention_since(queryable, nil), do: queryable

  defp maybe_filter_mention_since(queryable, since) do
    where(queryable, [em, m], m.inserted_at >= ^since)
  end

  defp unique_by_id(items) do
    {list, _seen} =
      Enum.reduce(items, {[], MapSet.new()}, fn item, {acc, seen} ->
        id = Map.get(item, :id)

        if is_nil(id) or MapSet.member?(seen, id) do
          {acc, seen}
        else
          {[item | acc], MapSet.put(seen, id)}
        end
      end)

    Enum.reverse(list)
  end

  defp truncate_text(text, length) when is_binary(text) do
    text
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> String.slice(0, length)
    |> case do
      "" -> "(empty memory)"
      value -> value
    end
  end

  defp truncate_text(_, _), do: "(empty memory)"

  defp short_id(id) when is_binary(id), do: String.slice(id, 0, 8)
  defp short_id(_), do: "unknown"

  defp entity_color("person"), do: "#f7931e"
  defp entity_color("organization"), do: "#93278f"
  defp entity_color("project"), do: "#00a99d"
  defp entity_color("location"), do: "#33475b"
  defp entity_color(_), do: "#6b7f8f"

  defp empty_graph do
    %{nodes: [], links: []}
  end
end
