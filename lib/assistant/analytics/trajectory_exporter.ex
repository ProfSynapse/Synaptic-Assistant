# lib/assistant/analytics/trajectory_exporter.ex — JSONL trajectory export.
#
# Writes conversation trajectories as JSONL files for future fine-tuning,
# analysis, and debugging. Each conversation turn appends a complete snapshot
# of the interaction (messages, tool calls, results, usage, model info).
#
# Format follows a training-data-friendly structure: one JSON object per line,
# each representing a full turn (user message → assistant response, including
# any intermediate tool calls and sub-agent dispatches).
#
# Related files:
#   - lib/assistant/analytics.ex (existing JSONL analytics events)
#   - lib/assistant/analytics/trajectory_format.ex (format helpers)
#   - lib/assistant/scheduler/workers/trajectory_export_worker.ex (Oban worker)
#   - lib/assistant/orchestrator/engine.ex (triggers export via PubSub)

defmodule Assistant.Analytics.TrajectoryExporter do
  @moduledoc """
  Exports conversation trajectories as JSONL for fine-tuning and analysis.

  Each exported line is a self-contained JSON object representing one
  conversation turn with full message history, tool call traces, model
  metadata, and token usage.

  ## File Layout

      tmp/trajectories/
        {user_id}/
          {conversation_id}.jsonl    # One line per turn

  ## Usage

      TrajectoryExporter.export_turn(%{
        conversation_id: "abc",
        user_id: "user-1",
        user_message: "Send an email to ...",
        assistant_response: "Done! I sent ...",
        messages: [...],
        dispatched_agents: %{...},
        usage: %{prompt_tokens: 100, completion_tokens: 50},
        model: "anthropic/claude-sonnet-4.6"
      })
  """

  alias Assistant.Analytics.TrajectoryFormat

  require Logger

  @default_base_path "tmp/trajectories"

  @doc """
  Exports a single conversation turn as a JSONL line.

  Appends one JSON object to the conversation's trajectory file.
  Creates directories as needed. Never raises — logs warnings on failure.

  ## Parameters

    * `attrs` - Map with:
      * `:conversation_id` - (required) Conversation identifier
      * `:user_id` - (required) User identifier
      * `:user_message` - The user's input text
      * `:assistant_response` - The assistant's final text response
      * `:messages` - Full message history list (system, user, assistant, tool)
      * `:dispatched_agents` - Map of agent_id => result for sub-agents
      * `:usage` - Token usage map with :prompt_tokens, :completion_tokens
      * `:model` - Model identifier string
      * `:mode` - Engine mode (:multi_agent or :single_loop)
      * `:channel` - Channel identifier
  """
  @spec export_turn(map()) :: :ok
  def export_turn(attrs) when is_map(attrs) do
    conversation_id = Map.get(attrs, :conversation_id, "unknown")
    user_id = Map.get(attrs, :user_id, "unknown")

    entry = TrajectoryFormat.build_turn_entry(attrs)
    line = Jason.encode!(entry) <> "\n"

    path = trajectory_path(user_id, conversation_id)
    File.mkdir_p!(Path.dirname(path))

    case File.write(path, line, [:append]) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("Failed to write trajectory",
          conversation_id: conversation_id,
          reason: inspect(reason)
        )

        :ok
    end
  rescue
    exception ->
      Logger.warning("Failed to export trajectory",
        conversation_id: Map.get(attrs, :conversation_id),
        reason: Exception.message(exception)
      )

      :ok
  end

  @doc """
  Exports a full conversation as a single JSONL file.

  Reads all messages from the database and writes them as a complete
  training trajectory. Used for bulk export / download.

  ## Parameters

    * `conversation_id` - The conversation to export
    * `opts` - Options:
      * `:output_path` - Custom output path (default: standard trajectory path)

  ## Returns

    * `{:ok, path}` — File written successfully
    * `{:error, reason}` — Export failed
  """
  @spec export_conversation(binary(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def export_conversation(conversation_id, opts \\ []) do
    alias Assistant.Memory.Store

    case Store.get_conversation(conversation_id) do
      {:ok, conversation} ->
        messages = Store.list_messages(conversation_id, limit: 10_000, order: :asc)
        user_id = conversation.user_id || "unknown"

        path =
          Keyword.get(opts, :output_path) ||
            trajectory_path(user_id, conversation_id)

        entry = TrajectoryFormat.build_conversation_entry(conversation, messages)
        line = Jason.encode!(entry) <> "\n"

        File.mkdir_p!(Path.dirname(path))

        case File.write(path, line, [:write]) do
          :ok -> {:ok, path}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Returns the file path for a conversation's trajectory file.
  """
  @spec trajectory_path(String.t(), String.t()) :: String.t()
  def trajectory_path(user_id, conversation_id) do
    base = Application.get_env(:assistant, :trajectories_base_path, @default_base_path)

    Path.join([
      base,
      sanitize_path_segment(user_id),
      "#{sanitize_path_segment(conversation_id)}.jsonl"
    ])
  end

  defp sanitize_path_segment(value) when is_binary(value) do
    value
    |> String.replace(~r/[^a-zA-Z0-9_-]/, "_")
    |> String.slice(0, 128)
  end

  defp sanitize_path_segment(nil), do: "unknown"
end
