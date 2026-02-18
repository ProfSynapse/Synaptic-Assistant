# lib/assistant/skills/memory/search.ex — Handler for memory.search_memories skill.
#
# Searches the user's memory entries using FTS + filters. This is the
# primary read skill that satisfies search-first enforcement for subsequent
# write skills.
#
# Related files:
#   - lib/assistant/memory/search.ex (search_memories/2)
#   - priv/skills/memory/search_memories.md (skill definition)

defmodule Assistant.Skills.Memory.Search do
  @moduledoc """
  Handler for the `memory.search_memories` skill.

  Searches memory entries via PostgreSQL full-text search with optional
  tag, category, and importance filters. Returns ranked results.
  """

  @behaviour Assistant.Skills.Handler

  alias Assistant.Memory.Search, as: MemorySearch
  alias Assistant.Skills.Result

  @impl true
  def execute(flags, context) do
    opts =
      []
      |> maybe_add(:query, flags["query"])
      |> maybe_add(:tags, parse_tags(flags["tags"] || flags["topics"]))
      |> maybe_add(:category, flags["category"])
      |> maybe_add(:importance_min, parse_float(flags["min_confidence"]))
      |> maybe_add(:limit, parse_int(flags["limit"]))

    case MemorySearch.search_memories(context.user_id, opts) do
      {:ok, entries} ->
        results =
          Enum.map(entries, fn e ->
            %{
              id: e.id,
              content: e.content,
              tags: e.tags,
              category: e.category,
              importance: e.importance && Decimal.to_float(e.importance),
              source_type: e.source_type,
              created_at: e.inserted_at
            }
          end)

        {:ok,
         %Result{
           status: :ok,
           content:
             Jason.encode!(%{
               results: results,
               total_count: length(results)
             }),
           metadata: %{result_count: length(results)}
         }}
    end
  end

  defp maybe_add(opts, _key, nil), do: opts
  defp maybe_add(opts, _key, []), do: opts
  defp maybe_add(opts, key, value), do: Keyword.put(opts, key, value)

  defp parse_tags(nil), do: nil
  defp parse_tags(tags) when is_list(tags), do: tags

  defp parse_tags(tags) when is_binary(tags) do
    tags |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))
  end

  defp parse_float(nil), do: nil
  defp parse_float(val) when is_float(val), do: val
  defp parse_float(val) when is_integer(val), do: val / 1

  defp parse_float(val) when is_binary(val) do
    case Float.parse(val) do
      {f, _} -> f
      :error -> nil
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
