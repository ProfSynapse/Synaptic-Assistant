# lib/assistant/skills/memory/get.ex — Handler for memory entry retrieval.
#
# Fetches a single memory entry by ID with preloaded entity mentions.
# Optionally includes the linked conversation message segment if
# segment_start_message_id and segment_end_message_id are set.
#
# Related files:
#   - lib/assistant/memory/store.ex (get_memory_entry/1, get_messages_in_range/3)

defmodule Assistant.Skills.Memory.Get do
  @moduledoc """
  Handler for retrieving a single memory entry by ID.

  Returns the full entry with entity mentions preloaded. If the entry
  has segment message IDs (from compaction), includes the original
  conversation transcript for that segment.
  """

  @behaviour Assistant.Skills.Handler

  alias Assistant.Memory.Store
  alias Assistant.Skills.Result

  @impl true
  def execute(flags, context) do
    entry_id = flags["id"] || flags["entry_id"]

    unless entry_id && entry_id != "" do
      {:ok,
       %Result{
         status: :error,
         content: "Missing required parameter: id (memory entry UUID)"
       }}
    else
      case Store.get_memory_entry(entry_id) do
        {:ok, entry} when entry.user_id != context.user_id ->
          {:ok,
           %Result{
             status: :error,
             content: "Memory entry not found: #{entry_id}"
           }}

        {:ok, entry} ->
          segment = maybe_fetch_segment(entry)

          result = %{
            id: entry.id,
            content: entry.content,
            tags: entry.tags,
            category: entry.category,
            importance: entry.importance && Decimal.to_float(entry.importance),
            source_type: entry.source_type,
            source_conversation_id: entry.source_conversation_id,
            entity_mentions: Enum.map(entry.entity_mentions, & &1.entity_id),
            created_at: entry.inserted_at,
            accessed_at: entry.accessed_at,
            segment: segment
          }

          # Touch accessed_at for decay tracking
          Store.update_memory_entry_accessed_at(entry.id)

          {:ok,
           %Result{
             status: :ok,
             content: Jason.encode!(result),
             metadata: %{entry_id: entry.id}
           }}

        {:error, :not_found} ->
          {:ok,
           %Result{
             status: :error,
             content: "Memory entry not found: #{entry_id}"
           }}
      end
    end
  end

  defp maybe_fetch_segment(entry) do
    with start_id when not is_nil(start_id) <- entry.segment_start_message_id,
         end_id when not is_nil(end_id) <- entry.segment_end_message_id,
         conv_id when not is_nil(conv_id) <- entry.source_conversation_id do
      messages = Store.get_messages_in_range(conv_id, start_id, end_id)

      Enum.map(messages, fn m ->
        %{role: m.role, content: m.content}
      end)
    else
      _ -> nil
    end
  end
end
