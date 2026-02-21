defmodule Assistant.MemoryExplorer do
  @moduledoc """
  Query helpers for browsing persisted memory entries in the settings UI.
  """

  import Ecto.Query

  alias Assistant.Repo
  alias Assistant.Schemas.MemoryEntry

  @default_limit 80

  @spec list_memories(keyword()) :: [map()]
  def list_memories(opts \\ []) do
    limit = Keyword.get(opts, :limit, @default_limit)
    user_id = normalize_text(Keyword.get(opts, :user_id, ""))
    query = normalize_text(Keyword.get(opts, :query, ""))
    category = normalize_text(Keyword.get(opts, :category, ""))
    source_type = normalize_text(Keyword.get(opts, :source_type, ""))
    tag = normalize_text(Keyword.get(opts, :tag, ""))
    source_conversation_id = normalize_text(Keyword.get(opts, :source_conversation_id, ""))
    since = Keyword.get(opts, :since)

    memory_query =
      from(m in MemoryEntry,
        order_by: [desc: m.inserted_at],
        limit: ^limit,
        select: %{
          id: m.id,
          content: m.content,
          tags: m.tags,
          category: m.category,
          source_type: m.source_type,
          importance: m.importance,
          user_id: m.user_id,
          source_conversation_id: m.source_conversation_id,
          embedding_model: m.embedding_model,
          decay_factor: m.decay_factor,
          accessed_at: m.accessed_at,
          segment_start_message_id: m.segment_start_message_id,
          segment_end_message_id: m.segment_end_message_id,
          inserted_at: m.inserted_at
        }
      )
      |> maybe_filter_user_id(user_id)
      |> maybe_filter_query(query)
      |> maybe_filter_category(category)
      |> maybe_filter_source_type(source_type)
      |> maybe_filter_tag(tag)
      |> maybe_filter_source_conversation_id(source_conversation_id)
      |> maybe_filter_since(since)

    Repo.all(memory_query)
    |> Enum.map(fn memory ->
      Map.put(memory, :preview, truncate_preview(memory.content))
    end)
  end

  @spec get_memory(String.t()) :: {:ok, map()} | {:error, :not_found}
  def get_memory(memory_id) when is_binary(memory_id) do
    case Repo.get(MemoryEntry, memory_id) do
      nil ->
        {:error, :not_found}

      memory ->
        {:ok,
         %{
           id: memory.id,
           content: memory.content,
           tags: memory.tags || [],
           category: memory.category,
           source_type: memory.source_type,
           importance: memory.importance,
           user_id: memory.user_id,
           source_conversation_id: memory.source_conversation_id,
           embedding_model: memory.embedding_model,
           decay_factor: memory.decay_factor,
           accessed_at: memory.accessed_at,
           segment_start_message_id: memory.segment_start_message_id,
           segment_end_message_id: memory.segment_end_message_id,
           inserted_at: memory.inserted_at
         }}
    end
  end

  @spec filter_options(keyword()) :: %{
          categories: [String.t()],
          source_types: [String.t()],
          tags: [String.t()]
        }
  def filter_options(opts \\ []) do
    user_id = normalize_text(Keyword.get(opts, :user_id, ""))

    categories =
      from(m in MemoryEntry,
        select: m.category,
        where: not is_nil(m.category),
        distinct: true,
        order_by: m.category
      )
      |> maybe_filter_user_id(user_id)
      |> Repo.all()
      |> Enum.reject(&(&1 in [nil, ""]))

    source_types =
      from(m in MemoryEntry,
        select: m.source_type,
        where: not is_nil(m.source_type),
        distinct: true,
        order_by: m.source_type
      )
      |> maybe_filter_user_id(user_id)
      |> Repo.all()
      |> Enum.reject(&(&1 in [nil, ""]))

    tags =
      from(m in MemoryEntry,
        select: m.tags
      )
      |> maybe_filter_user_id(user_id)
      |> Repo.all()
      |> List.flatten()
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.uniq()
      |> Enum.sort()

    %{categories: categories, source_types: source_types, tags: tags}
  end

  defp maybe_filter_user_id(queryable, ""), do: queryable
  defp maybe_filter_user_id(queryable, user_id), do: where(queryable, [m], m.user_id == ^user_id)

  defp maybe_filter_query(queryable, ""), do: queryable

  defp maybe_filter_query(queryable, query) do
    pattern = "%#{query}%"
    where(queryable, [m], ilike(m.content, ^pattern))
  end

  defp maybe_filter_category(queryable, ""), do: queryable

  defp maybe_filter_category(queryable, category),
    do: where(queryable, [m], m.category == ^category)

  defp maybe_filter_source_type(queryable, ""), do: queryable

  defp maybe_filter_source_type(queryable, source_type),
    do: where(queryable, [m], m.source_type == ^source_type)

  defp maybe_filter_tag(queryable, ""), do: queryable

  defp maybe_filter_tag(queryable, tag),
    do: where(queryable, [m], fragment("? = ANY(?)", ^tag, m.tags))

  defp maybe_filter_source_conversation_id(queryable, ""), do: queryable

  defp maybe_filter_source_conversation_id(queryable, source_conversation_id),
    do: where(queryable, [m], m.source_conversation_id == ^source_conversation_id)

  defp maybe_filter_since(queryable, nil), do: queryable

  defp maybe_filter_since(queryable, %DateTime{} = since),
    do: where(queryable, [m], m.inserted_at >= ^since)

  defp maybe_filter_since(queryable, _invalid), do: queryable

  defp truncate_preview(content) when is_binary(content) do
    content
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> String.slice(0, 160)
  end

  defp truncate_preview(_), do: ""

  defp normalize_text(value) when is_binary(value), do: String.trim(value)
  defp normalize_text(value) when is_atom(value), do: value |> Atom.to_string() |> String.trim()
  defp normalize_text(_), do: ""
end
