# lib/assistant/skills/memory/save.ex — Handler for memory.save_memory skill.
#
# Persists a new memory entry for the current user. The MemoryAgent's
# search-first enforcement ensures a search was performed before this
# handler is invoked.
#
# Related files:
#   - lib/assistant/memory/store.ex (create_memory_entry/1)
#   - priv/skills/memory/save_memory.md (skill definition)
#   - lib/assistant/memory/skill_executor.ex (search-first enforcement)

defmodule Assistant.Skills.Memory.Save do
  @moduledoc """
  Handler for the `memory.save_memory` skill.

  Creates a new `MemoryEntry` with the provided content, tags, category,
  importance, and source type. Scopes the entry to the current user and
  conversation.
  """

  @behaviour Assistant.Skills.Handler

  alias Assistant.Memory.Store
  alias Assistant.Skills.Result

  require Logger

  @impl true
  def execute(flags, context) do
    content = flags["content"]

    unless content && content != "" do
      {:ok,
       %Result{
         status: :error,
         content: "Missing required parameter: content"
       }}
    else
      attrs = build_attrs(flags, context)

      case Store.create_memory_entry(attrs) do
        {:ok, entry} ->
          Logger.info("Memory saved",
            entry_id: entry.id,
            user_id: context.user_id,
            category: entry.category
          )

          {:ok,
           %Result{
             status: :ok,
             content:
               Jason.encode!(%{
                 id: entry.id,
                 content: entry.content,
                 tags: entry.tags,
                 category: entry.category,
                 created_at: entry.inserted_at
               }),
             side_effects: [:memory_saved],
             metadata: %{entry_id: entry.id}
           }}

        {:error, changeset} ->
          {:ok,
           %Result{
             status: :error,
             content: "Failed to save memory: #{inspect(changeset.errors)}"
           }}
      end
    end
  end

  defp build_attrs(flags, context) do
    %{
      content: flags["content"],
      user_id: context.user_id,
      source_conversation_id: context.conversation_id,
      source_type: flags["source_type"] || flags["source-type"] || "conversation",
      tags: parse_tags(flags["tags"] || flags["topics"]),
      category: flags["category"],
      importance: parse_importance(flags["importance"] || flags["confidence"])
    }
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  defp parse_tags(nil), do: []
  defp parse_tags(tags) when is_list(tags), do: tags

  defp parse_tags(tags) when is_binary(tags) do
    tags |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))
  end

  defp parse_importance(nil), do: nil
  defp parse_importance(val) when is_float(val), do: Decimal.from_float(val)
  defp parse_importance(val) when is_integer(val), do: Decimal.new(val)
  defp parse_importance(%Decimal{} = val), do: val

  defp parse_importance(val) when is_binary(val) do
    case Float.parse(val) do
      {f, _} -> Decimal.from_float(f)
      :error -> nil
    end
  end
end
