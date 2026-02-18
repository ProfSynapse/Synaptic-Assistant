# lib/assistant/skills/memory/query_entity_graph.ex — Handler for memory.query_entity_graph skill.
#
# Searches entities by name and retrieves their active relations.
# This is a read skill that satisfies the search-first requirement
# for subsequent write operations.
#
# Related files:
#   - lib/assistant/memory/search.ex (search_entities/2, get_entity_relations/2)
#   - priv/skills/memory/query_entity_graph.md (skill definition)

defmodule Assistant.Skills.Memory.QueryEntityGraph do
  @moduledoc """
  Handler for the `memory.query_entity_graph` skill.

  Searches for entities by name fragment, then retrieves their active
  relations (optionally filtered by relation type). Supports depth
  parameter for multi-hop traversal.
  """

  @behaviour Assistant.Skills.Handler

  alias Assistant.Memory.Search, as: MemorySearch
  alias Assistant.Skills.Result

  @max_depth 3

  @impl true
  def execute(flags, context) do
    entity_name = flags["entity_name"] || flags["entity"]
    entity_type = flags["entity_type"] || flags["type"]
    depth = min(parse_int(flags["depth"]) || 1, @max_depth)
    relation_types = flags["relation_types"]

    unless entity_name && entity_name != "" do
      {:ok,
       %Result{
         status: :error,
         content: "Missing required parameter: entity_name"
       }}
    else
      case MemorySearch.search_entities(context.user_id, name: entity_name, entity_type: entity_type, limit: 1) do
        {:ok, [entity | _]} ->
          relations = traverse_relations(entity.id, depth, relation_types)

          result = %{
            entity: %{
              id: entity.id,
              name: entity.name,
              entity_type: entity.entity_type,
              metadata: entity.metadata,
              created_at: entity.inserted_at
            },
            relations: relations,
            total_relations: length(relations)
          }

          {:ok,
           %Result{
             status: :ok,
             content: Jason.encode!(result),
             metadata: %{entity_id: entity.id, depth: depth}
           }}

        {:ok, []} ->
          {:ok,
           %Result{
             status: :ok,
             content: Jason.encode!(%{entity: nil, relations: [], total_relations: 0}),
             metadata: %{result_count: 0}
           }}
      end
    end
  end

  # Traverse relations up to `depth` hops. Depth 1 = direct relations only.
  defp traverse_relations(entity_id, depth, relation_types) do
    traverse_relations(entity_id, depth, relation_types, MapSet.new())
  end

  defp traverse_relations(_entity_id, 0, _relation_types, _visited), do: []

  defp traverse_relations(entity_id, depth, relation_types, visited) do
    if MapSet.member?(visited, entity_id) do
      []
    else
      visited = MapSet.put(visited, entity_id)

      opts =
        case relation_types do
          nil -> []
          type when is_binary(type) -> [relation_type: type]
          _ -> []
        end

      {:ok, direct_relations} = MemorySearch.get_entity_relations(entity_id, opts)

      formatted =
        Enum.map(direct_relations, fn rel ->
          {direction, related_entity} =
            if rel.source_entity_id == entity_id do
              {"outgoing", rel.target_entity}
            else
              {"incoming", rel.source_entity}
            end

          %{
            id: rel.id,
            direction: direction,
            related_entity: %{
              id: related_entity.id,
              name: related_entity.name,
              entity_type: related_entity.entity_type
            },
            relation_type: rel.relation_type,
            confidence: rel.confidence && Decimal.to_float(rel.confidence),
            valid_from: rel.valid_from,
            valid_to: rel.valid_to
          }
        end)

      if depth <= 1 do
        formatted
      else
        # Collect related entity IDs for next hop
        next_ids =
          direct_relations
          |> Enum.flat_map(fn rel ->
            [rel.source_entity_id, rel.target_entity_id]
          end)
          |> Enum.reject(&(&1 == entity_id))
          |> Enum.uniq()
          |> Enum.reject(&MapSet.member?(visited, &1))

        deeper =
          Enum.flat_map(next_ids, fn next_id ->
            traverse_relations(next_id, depth - 1, relation_types, visited)
          end)

        formatted ++ deeper
      end
    end
  end

  defp parse_int(nil), do: nil
  defp parse_int(val) when is_integer(val), do: val

  defp parse_int(val) when is_binary(val) do
    case Integer.parse(val) do
      {i, _} -> i
      :error -> nil
    end
  end
end
