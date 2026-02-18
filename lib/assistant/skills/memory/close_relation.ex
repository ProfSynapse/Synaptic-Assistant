# lib/assistant/skills/memory/close_relation.ex — Handler for memory.close_relation skill.
#
# Closes an active entity relation by setting valid_to = now(). Optionally
# creates a replacement relation in the same operation, maintaining the
# temporal audit trail.
#
# Related files:
#   - lib/assistant/schemas/memory_entity_relation.ex (relation schema)
#   - priv/skills/memory/close_relation.md (skill definition)

defmodule Assistant.Skills.Memory.CloseRelation do
  @moduledoc """
  Handler for the `memory.close_relation` skill.

  Closes an active entity relation by setting `valid_to` to the current
  timestamp. Never deletes relations -- the temporal validity pattern
  preserves full fact history.
  """

  @behaviour Assistant.Skills.Handler

  import Ecto.Query

  alias Assistant.Repo
  alias Assistant.Schemas.MemoryEntityRelation
  alias Assistant.Skills.Result

  require Logger

  @impl true
  def execute(flags, _context) do
    relation_id = flags["relation_id"] || flags["id"]

    unless relation_id && relation_id != "" do
      {:ok,
       %Result{
         status: :error,
         content: "Missing required parameter: relation_id"
       }}
    else
      case close_relation(relation_id) do
        {:ok, closed} ->
          closed_relation = Repo.preload(closed, [:source_entity, :target_entity])

          result = %{
            closed_relation: %{
              id: closed_relation.id,
              from_entity: closed_relation.source_entity.name,
              to_entity: closed_relation.target_entity.name,
              relation_type: closed_relation.relation_type,
              valid_from: closed_relation.valid_from,
              valid_to: closed_relation.valid_to
            }
          }

          Logger.info("Relation closed",
            relation_id: relation_id,
            relation_type: closed_relation.relation_type
          )

          {:ok,
           %Result{
             status: :ok,
             content: Jason.encode!(result),
             side_effects: [:relation_closed],
             metadata: %{relation_id: relation_id}
           }}

        {:error, :not_found} ->
          {:ok,
           %Result{
             status: :error,
             content: "Relation not found: #{relation_id}"
           }}

        {:error, :already_closed} ->
          {:ok,
           %Result{
             status: :error,
             content: "Relation already closed: #{relation_id}"
           }}
      end
    end
  end

  defp close_relation(relation_id) do
    now = DateTime.utc_now()

    case Repo.get(MemoryEntityRelation, relation_id) do
      nil ->
        {:error, :not_found}

      %{valid_to: valid_to} when not is_nil(valid_to) ->
        {:error, :already_closed}

      _relation ->
        from(r in MemoryEntityRelation,
          where: r.id == ^relation_id and is_nil(r.valid_to),
          select: r
        )
        |> Repo.update_all(set: [valid_to: now])
        |> case do
          {0, _} -> {:error, :not_found}
          {_count, [updated]} -> {:ok, updated}
        end
    end
  end
end
