# lib/assistant/analytics/trajectory_format.ex — Trajectory data formatting.
#
# Builds structured maps from raw conversation data for JSONL serialization.
# Separates formatting concerns from I/O (TrajectoryExporter handles writes).
#
# Related files:
#   - lib/assistant/analytics/trajectory_exporter.ex (I/O layer)
#   - lib/assistant/schemas/conversation.ex
#   - lib/assistant/schemas/message.ex

defmodule Assistant.Analytics.TrajectoryFormat do
  @moduledoc false

  @doc """
  Builds a turn-level trajectory entry from engine state.

  Returns a map suitable for JSON encoding. Includes the full message
  history at the point of this turn plus metadata.
  """
  @spec build_turn_entry(map()) :: map()
  def build_turn_entry(attrs) do
    %{
      type: "turn",
      version: 1,
      conversation_id: attrs[:conversation_id],
      user_id: attrs[:user_id],
      channel: to_string(attrs[:channel] || "unknown"),
      mode: to_string(attrs[:mode] || "multi_agent"),
      model: attrs[:model],
      user_message: attrs[:user_message],
      assistant_response: attrs[:assistant_response],
      messages: format_messages(attrs[:messages] || []),
      agents: format_agents(attrs[:dispatched_agents] || %{}),
      usage: format_usage(attrs[:usage] || %{}),
      iteration_count: attrs[:iteration_count] || 0,
      timestamp: now_iso8601()
    }
  end

  @doc """
  Builds a conversation-level trajectory entry from DB records.

  Used for full-conversation export (bulk / download).
  """
  @spec build_conversation_entry(map(), [map()]) :: map()
  def build_conversation_entry(conversation, messages) do
    %{
      type: "conversation",
      version: 1,
      conversation_id: conversation.id,
      user_id: conversation.user_id,
      channel: conversation.channel,
      agent_type: conversation.agent_type,
      status: conversation.status,
      parent_conversation_id: conversation.parent_conversation_id,
      started_at: format_datetime(conversation.started_at),
      completed_at: format_datetime(conversation.last_active_at),
      summary: conversation.summary,
      summary_version: conversation.summary_version,
      messages: Enum.map(messages, &format_db_message/1),
      message_count: length(messages),
      timestamp: now_iso8601()
    }
  end

  # --- Private Helpers ---

  # Format in-memory messages (from Engine state) for export.
  # These are maps with string keys like "role", "content", "tool_calls".
  defp format_messages(messages) do
    messages
    |> Enum.with_index()
    |> Enum.map(fn {msg, idx} ->
      base = %{
        index: idx,
        role: msg[:role] || msg["role"]
      }

      base
      |> maybe_put(:content, msg[:content] || msg["content"])
      |> maybe_put(:tool_calls, format_tool_calls(msg[:tool_calls] || msg["tool_calls"]))
      |> maybe_put(:tool_call_id, msg[:tool_call_id] || msg["tool_call_id"])
    end)
  end

  defp format_tool_calls(nil), do: nil
  defp format_tool_calls([]), do: nil

  defp format_tool_calls(tool_calls) when is_list(tool_calls) do
    Enum.map(tool_calls, fn tc ->
      %{
        id: tc[:id] || tc["id"],
        function: %{
          name:
            get_in(tc, [:function, :name]) ||
              get_in(tc, ["function", "name"]) || "unknown",
          arguments:
            get_in(tc, [:function, :arguments]) ||
              get_in(tc, ["function", "arguments"]) || ""
        }
      }
    end)
  end

  defp format_tool_calls(_), do: nil

  defp format_agents(dispatched) when is_map(dispatched) do
    Enum.map(dispatched, fn {agent_id, result} ->
      %{
        agent_id: agent_id,
        status: to_string(result[:status] || "unknown"),
        result: truncate(result[:result], 2_000),
        tool_calls_used: result[:tool_calls_used] || 0,
        duration_ms: result[:duration_ms] || 0
      }
    end)
  end

  defp format_agents(_), do: []

  defp format_usage(usage) when is_map(usage) do
    %{
      prompt_tokens: usage[:prompt_tokens] || usage["prompt_tokens"] || 0,
      completion_tokens: usage[:completion_tokens] || usage["completion_tokens"] || 0
    }
  end

  # Format a DB Message schema struct for export.
  defp format_db_message(%{} = msg) do
    %{
      id: Map.get(msg, :id),
      role: Map.get(msg, :role),
      content: Map.get(msg, :content),
      tool_calls: Map.get(msg, :tool_calls),
      tool_results: Map.get(msg, :tool_results),
      token_count: Map.get(msg, :token_count),
      timestamp: format_datetime(Map.get(msg, :inserted_at))
    }
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp truncate(nil, _max), do: nil
  defp truncate(text, max) when is_binary(text) and byte_size(text) <= max, do: text
  defp truncate(text, max) when is_binary(text), do: String.slice(text, 0, max) <> "..."
  defp truncate(other, _max), do: inspect(other)

  defp format_datetime(nil), do: nil

  defp format_datetime(%DateTime{} = dt) do
    dt |> DateTime.truncate(:second) |> DateTime.to_iso8601()
  end

  defp format_datetime(other), do: to_string(other)

  defp now_iso8601, do: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
end
