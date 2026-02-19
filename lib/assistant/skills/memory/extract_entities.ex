# lib/assistant/skills/memory/extract_entities.ex — Handler for memory.extract_entities skill.
#
# Upserts named entities and relations into the knowledge graph.
# Expects pre-structured entity and relation data (typically produced
# by the MemoryAgent's LLM analysis of conversation text).
#
# Related files:
#   - lib/assistant/schemas/memory_entity.ex (entity schema)
#   - lib/assistant/schemas/memory_entity_relation.ex (relation schema)
#   - priv/skills/memory/extract_entities.md (skill definition)

defmodule Assistant.Skills.Memory.ExtractEntities do
  @moduledoc """
  Handler for the `memory.extract_entities` skill.

  Receives structured entity and relation data, upserts entities into
  `memory_entities` (using the unique constraint on `(user_id, name,
  entity_type)` for deduplication), and inserts relations into
  `memory_entity_relations`.
  """

  @behaviour Assistant.Skills.Handler

  import Ecto.Query

  alias Assistant.Repo
  alias Assistant.Schemas.{MemoryEntity, MemoryEntityRelation}
  alias Assistant.Skills.Result

  require Logger

  @impl true
  def execute(flags, context) do
    entities_raw = flags["entities"] || []
    relations_raw = flags["relations"] || []

    entities_data = parse_json_if_string(entities_raw)
    relations_data = parse_json_if_string(relations_raw)

    {entities_result, entity_map} = upsert_entities(entities_data, context.user_id)
    relations_result = insert_relations(relations_data, entity_map, context)

    total_entities = length(entities_result)
    total_relations = length(relations_result)

    Logger.info("Entities extracted",
      user_id: context.user_id,
      entities: total_entities,
      relations: total_relations
    )

    {:ok,
     %Result{
       status: :ok,
       content:
         Jason.encode!(%{
           entities_upserted: total_entities,
           relations_upserted: total_relations,
           entities_found: entities_result,
           relations_found: relations_result
         }),
       side_effects: [:entities_extracted],
       metadata: %{
         entities_count: total_entities,
         relations_count: total_relations
       }
     }}
  end

  # Upsert entities: insert or fetch existing by (user_id, name, entity_type).
  # Returns {result_list, entity_name_to_id_map}.
  defp upsert_entities(entities_data, user_id) do
    results =
      Enum.map(entities_data, fn entity_data ->
        name = entity_data["name"]
        entity_type = entity_data["entity_type"] || entity_data["type"]

        case find_entity(user_id, name, entity_type) do
          nil ->
            attrs = %{
              name: name,
              entity_type: entity_type,
              user_id: user_id,
              metadata: entity_data["metadata"] || entity_data["attributes"] || %{}
            }

            case Repo.insert(MemoryEntity.changeset(%MemoryEntity{}, attrs)) do
              {:ok, entity} ->
                %{name: entity.name, entity_type: entity.entity_type, id: entity.id, is_new: true}

              {:error, _changeset} ->
                # Race condition: another process inserted between check and insert
                case find_entity(user_id, name, entity_type) do
                  nil ->
                    %{name: name, entity_type: entity_type, error: "insert_failed"}

                  entity ->
                    %{
                      name: entity.name,
                      entity_type: entity.entity_type,
                      id: entity.id,
                      is_new: false
                    }
                end
            end

          entity ->
            %{name: entity.name, entity_type: entity.entity_type, id: entity.id, is_new: false}
        end
      end)

    entity_map =
      results
      |> Enum.filter(&Map.has_key?(&1, :id))
      |> Map.new(fn r -> {r.name, r.id} end)

    {results, entity_map}
  end

  defp find_entity(user_id, name, entity_type) do
    from(e in MemoryEntity,
      where: e.user_id == ^user_id and e.name == ^name and e.entity_type == ^entity_type
    )
    |> Repo.one()
  end

  # Insert relations using the entity name-to-id map.
  defp insert_relations(relations_data, entity_map, context) do
    Enum.map(relations_data, fn rel_data ->
      source_name = rel_data["from_entity"] || rel_data["source"]
      target_name = rel_data["to_entity"] || rel_data["target"]
      relation_type = rel_data["relation_type"] || rel_data["type"]

      source_id = Map.get(entity_map, source_name)
      target_id = Map.get(entity_map, target_name)

      cond do
        is_nil(source_id) ->
          %{from_entity: source_name, to_entity: target_name, error: "source entity not found"}

        is_nil(target_id) ->
          %{from_entity: source_name, to_entity: target_name, error: "target entity not found"}

        source_id == target_id ->
          %{from_entity: source_name, to_entity: target_name, error: "self-relation not allowed"}

        true ->
          attrs =
            %{
              source_entity_id: source_id,
              target_entity_id: target_id,
              relation_type: relation_type,
              metadata: rel_data["attributes"] || rel_data["metadata"] || %{},
              confidence: parse_confidence(rel_data["confidence"]),
              source_memory_entry_id: context.metadata[:source_memory_entry_id]
            }
            |> Enum.reject(fn {_k, v} -> is_nil(v) end)
            |> Map.new()

          case Repo.insert(MemoryEntityRelation.changeset(%MemoryEntityRelation{}, attrs)) do
            {:ok, rel} ->
              %{
                from_entity: source_name,
                to_entity: target_name,
                relation_type: rel.relation_type,
                id: rel.id,
                is_new: true
              }

            {:error, _changeset} ->
              %{
                from_entity: source_name,
                to_entity: target_name,
                relation_type: relation_type,
                is_new: false
              }
          end
      end
    end)
  end

  defp parse_confidence(nil), do: nil
  defp parse_confidence(val) when is_float(val), do: Decimal.from_float(val)
  defp parse_confidence(val) when is_integer(val), do: Decimal.new(val)
  defp parse_confidence(%Decimal{} = val), do: val
  defp parse_confidence(_), do: nil

  defp parse_json_if_string(data) when is_binary(data) do
    case Jason.decode(data) do
      {:ok, parsed} when is_list(parsed) -> parsed
      _ -> []
    end
  end

  defp parse_json_if_string(data) when is_list(data), do: data
  defp parse_json_if_string(_), do: []
end
