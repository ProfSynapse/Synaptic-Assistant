defmodule Assistant.Workspace do
  @moduledoc """
  Workspace read model and chat actions for the unified conversation UI.
  """

  import Ecto.Query, warn: false

  alias Assistant.Memory.Store
  alias Assistant.Orchestrator.{Engine, SubAgent}
  alias Assistant.Repo
  alias Assistant.Schemas.{MemoryEntry, Message}

  @default_message_limit 200

  @spec load(binary(), keyword()) :: {:ok, map()} | {:error, term()}
  def load(user_id, opts \\ []) when is_binary(user_id) do
    limit = Keyword.get(opts, :limit, @default_message_limit)

    with {:ok, conversation} <- Store.get_or_create_perpetual_conversation(user_id) do
      messages =
        conversation.id
        |> Store.list_messages(limit: limit, order: :desc)
        |> Enum.reverse()

      message_count =
        from(m in Message, where: m.conversation_id == ^conversation.id, select: count(m.id))
        |> Repo.one()
        |> Kernel.||(0)

      {feed_items, tool_index, sub_agent_index} = build_feed(messages)

      {:ok,
       %{
         conversation: conversation,
         feed_items: feed_items,
         tool_index: tool_index,
         sub_agent_index: sub_agent_index,
         message_count: message_count,
         truncated?: message_count > limit
       }}
    end
  end

  @spec send_message(binary(), binary(), binary()) :: {:ok, String.t()} | {:error, term()}
  def send_message(user_id, conversation_id, content)
      when is_binary(user_id) and is_binary(conversation_id) and is_binary(content) do
    with :ok <- ensure_engine_started(user_id, conversation_id),
         {:ok, response} <-
           Engine.send_message(user_id, content, metadata: in_app_message_metadata()) do
      {:ok, response}
    end
  end

  @spec tool_detail(map(), binary()) :: map() | nil
  def tool_detail(tool_index, inspect_id) when is_map(tool_index),
    do: Map.get(tool_index, inspect_id)

  @spec sub_agent_detail(binary(), map(), binary()) :: map() | nil
  def sub_agent_detail(conversation_id, sub_agent_index, inspect_id)
      when is_binary(conversation_id) and is_map(sub_agent_index) do
    case Map.get(sub_agent_index, inspect_id) do
      nil -> nil
      base -> hydrate_sub_agent_detail(conversation_id, base)
    end
  end

  defp build_feed(messages) do
    result_by_call_id = build_tool_result_map(messages)

    Enum.reduce(messages, {[], %{}, %{}}, fn message, {items, tool_index, sub_agent_index} ->
      message_item = build_message_item(message)

      {activity_item, activity_tool_index, activity_sub_agent_index} =
        build_activity_item(message, result_by_call_id)

      updated_items =
        items
        |> maybe_append(message_item)
        |> maybe_append(activity_item)

      {
        updated_items,
        Map.merge(tool_index, activity_tool_index),
        Map.merge(sub_agent_index, activity_sub_agent_index)
      }
    end)
  end

  defp maybe_append(items, nil), do: items
  defp maybe_append(items, item), do: items ++ [item]

  defp build_message_item(%Message{role: role, content: content} = message)
       when role in ["user", "assistant"] do
    if present?(content) do
      source_label = source_label_for_message(role, message.metadata)

      %{
        id: "message:#{message.id}",
        type: :message,
        role: if(role == "user", do: :user, else: :assistant),
        content: content,
        inserted_at: message.inserted_at,
        source_label: source_label
      }
    else
      nil
    end
  end

  defp build_message_item(_message), do: nil

  defp source_label_for_message("user", metadata) do
    source = source_map(metadata)
    kind = source |> map_value(:kind) |> normalize_text()
    channel = source |> map_value(:channel) |> normalize_text()

    cond do
      kind == "in_app" or channel == "in_app" ->
        "In App"

      is_binary(channel) ->
        label = source_channel_label(channel)

        if kind == "channel_replay" do
          "#{label} Replay"
        else
          label
        end

      true ->
        nil
    end
  end

  defp source_label_for_message(_role, _metadata), do: nil

  defp source_map(%{} = metadata) do
    case map_value(metadata, :source) do
      %{} = source -> source
      _ -> %{}
    end
  end

  defp source_map(_), do: %{}

  defp source_channel_label("google_chat"), do: "Google Chat"
  defp source_channel_label("slack"), do: "Slack"
  defp source_channel_label("telegram"), do: "Telegram"
  defp source_channel_label("discord"), do: "Discord"
  defp source_channel_label("in_app"), do: "In App"
  defp source_channel_label(channel) when is_binary(channel), do: titleize(channel)

  defp build_activity_item(%Message{role: "assistant"} = message, result_by_call_id) do
    tool_calls = normalize_tool_calls(message.tool_calls)

    if tool_calls == [] do
      {nil, %{}, %{}}
    else
      {tools, sub_agents} =
        tool_calls
        |> Enum.with_index(1)
        |> Enum.reduce({[], []}, fn {tool_call, idx}, {tools_acc, sub_agents_acc} ->
          parsed = parse_tool_call(message, tool_call, idx, result_by_call_id)

          case parsed do
            {:tool, tool_data} -> {[tool_data | tools_acc], sub_agents_acc}
            {:sub_agent, sub_agent_data} -> {tools_acc, [sub_agent_data | sub_agents_acc]}
          end
        end)

      tools = Enum.reverse(tools)
      sub_agents = Enum.reverse(sub_agents)

      activity_item = %{
        id: "activity:#{message.id}",
        type: :activity,
        inserted_at: message.inserted_at,
        tools: tools,
        sub_agents: sub_agents
      }

      tool_index =
        tools
        |> Enum.map(fn tool -> {tool.inspect_id, tool} end)
        |> Map.new()

      sub_agent_index =
        sub_agents
        |> Enum.map(fn sub_agent -> {sub_agent.inspect_id, sub_agent} end)
        |> Map.new()

      {activity_item, tool_index, sub_agent_index}
    end
  end

  defp build_activity_item(_message, _result_by_call_id), do: {nil, %{}, %{}}

  defp parse_tool_call(message, tool_call, idx, result_by_call_id) do
    tool_call_id = Map.get(tool_call, "id") || Map.get(tool_call, :id) || "call-#{idx}"
    function = Map.get(tool_call, "function") || Map.get(tool_call, :function) || %{}
    tool_name = Map.get(function, "name") || Map.get(function, :name) || "unknown"
    arguments_raw = Map.get(function, "arguments") || Map.get(function, :arguments) || %{}
    {arguments, arguments_pretty} = decode_arguments(arguments_raw)
    result_content = Map.get(result_by_call_id, tool_call_id)

    if tool_name == "dispatch_agent" do
      agent_id = arguments["agent_id"] || "agent-#{idx}"
      mission = arguments["mission"]
      context = arguments["context"]
      live_snapshot = live_sub_agent_snapshot(agent_id)

      status =
        if live_snapshot do
          live_snapshot.status
        else
          infer_dispatch_status(result_content)
        end

      {:sub_agent,
       %{
         inspect_id: "sub-agent:#{message.id}:#{agent_id}:#{tool_call_id}",
         agent_id: agent_id,
         mission: mission,
         context: context,
         status: status,
         result_content: result_content,
         inserted_at: message.inserted_at,
         live_snapshot: live_snapshot
       }}
    else
      {:tool,
       %{
         inspect_id: "tool:#{message.id}:#{tool_call_id}",
         tool_call_id: tool_call_id,
         name: tool_name,
         arguments: arguments,
         arguments_pretty: arguments_pretty,
         result_content: result_content,
         status: infer_tool_status(result_content),
         inserted_at: message.inserted_at
       }}
    end
  end

  defp build_tool_result_map(messages) do
    Enum.reduce(messages, %{}, fn
      %Message{role: "tool_result", tool_results: tool_results, content: content}, acc ->
        tool_call_id =
          case tool_results do
            %{} = map -> Map.get(map, "tool_call_id") || Map.get(map, :tool_call_id)
            _ -> nil
          end

        if is_binary(tool_call_id) do
          Map.put(acc, tool_call_id, content)
        else
          acc
        end

      _, acc ->
        acc
    end)
  end

  defp normalize_tool_calls(tool_calls) when is_list(tool_calls), do: tool_calls
  defp normalize_tool_calls(_), do: []

  defp decode_arguments(arguments_raw) when is_binary(arguments_raw) do
    case Jason.decode(arguments_raw) do
      {:ok, %{} = parsed} ->
        {parsed, encode_pretty(parsed)}

      {:ok, parsed} ->
        wrapped = %{"value" => parsed}
        {wrapped, encode_pretty(wrapped)}

      {:error, _} ->
        {%{"raw" => arguments_raw}, arguments_raw}
    end
  end

  defp decode_arguments(%{} = arguments_raw), do: {arguments_raw, encode_pretty(arguments_raw)}
  defp decode_arguments(_), do: {%{}, "{}"}

  defp encode_pretty(map) do
    case Jason.encode(map, pretty: true) do
      {:ok, json} -> json
      {:error, _} -> "{}"
    end
  end

  defp infer_tool_status(result_content) when is_binary(result_content) do
    normalized = String.downcase(result_content)

    cond do
      String.contains?(normalized, "failed") or String.contains?(normalized, "error") ->
        :failed

      true ->
        :completed
    end
  end

  defp infer_tool_status(_), do: :running

  defp infer_dispatch_status(result_content) when is_binary(result_content) do
    normalized = String.downcase(result_content)

    cond do
      String.contains?(normalized, "failed") or String.contains?(normalized, "error") ->
        :failed

      String.contains?(normalized, "timeout") ->
        :timeout

      String.contains?(normalized, "completed") ->
        :completed

      String.contains?(normalized, "running") or String.contains?(normalized, "pending") ->
        :running

      true ->
        :completed
    end
  end

  defp infer_dispatch_status(_), do: :running

  defp hydrate_sub_agent_detail(conversation_id, base) do
    live_snapshot = live_sub_agent_snapshot(base.agent_id) || base.live_snapshot
    persisted = latest_sub_agent_memory(conversation_id, base.agent_id)
    parsed = parse_persisted_agent_content(persisted && persisted.content)

    status =
      cond do
        live_snapshot -> live_snapshot.status
        parsed.status -> parsed.status
        true -> base.status
      end

    result_text =
      cond do
        live_snapshot && present?(live_snapshot.result) -> live_snapshot.result
        present?(base.result_content) -> base.result_content
        true -> nil
      end

    transcript_data =
      cond do
        live_snapshot && present?(live_snapshot.partial_history) ->
          %{
            mode: :live,
            content: maybe_append_reason(live_snapshot.partial_history, live_snapshot.reason)
          }

        live_snapshot && present?(live_snapshot.reason) ->
          %{mode: :live, content: "Awaiting orchestrator input: #{live_snapshot.reason}"}

        parsed.transcript && present?(parsed.transcript) ->
          %{mode: :historical, content: parsed.transcript}

        present?(result_text) ->
          %{mode: :result, content: result_text}

        true ->
          %{mode: :empty, content: "No transcript is available for this run yet."}
      end

    %{
      base
      | status: status,
        result_text: result_text,
        tool_calls_used: if(live_snapshot, do: live_snapshot.tool_calls_used),
        duration_ms: if(live_snapshot, do: live_snapshot.duration_ms),
        transcript_mode: transcript_data.mode,
        transcript_text: transcript_data.content,
        mission: base.mission || parsed.mission
    }
  end

  defp maybe_append_reason(history, nil), do: history

  defp maybe_append_reason(history, reason),
    do: history <> "\n\nAwaiting orchestrator input: #{reason}"

  defp latest_sub_agent_memory(conversation_id, agent_id) do
    tag = "agent:#{agent_id}"

    from(m in MemoryEntry,
      where:
        m.source_conversation_id == ^conversation_id and
          m.source_type == "agent_result" and
          fragment("? = ANY(?)", ^tag, m.tags),
      order_by: [desc: m.inserted_at],
      limit: 1
    )
    |> Repo.one()
  end

  defp parse_persisted_agent_content(nil), do: %{status: nil, mission: nil, transcript: nil}

  defp parse_persisted_agent_content(content) when is_binary(content) do
    status =
      case Regex.run(~r/^Status:\s*(.+)$/m, content, capture: :all_but_first) do
        [raw] -> normalize_status(raw)
        _ -> nil
      end

    mission =
      case String.split(content, "\n\nMission: ", parts: 2) do
        [_header, tail] ->
          case String.split(tail, "\n\nTranscript:\n", parts: 2) do
            [mission_text, _transcript] -> mission_text
            [mission_text] -> mission_text
            _ -> nil
          end

        _ ->
          nil
      end

    transcript =
      case String.split(content, "\n\nTranscript:\n", parts: 2) do
        [_head, transcript_text] -> transcript_text
        _ -> nil
      end

    %{status: status, mission: mission, transcript: transcript}
  end

  defp normalize_status(value) when is_binary(value) do
    case value |> String.trim() |> String.downcase() do
      "running" -> :running
      "awaiting_orchestrator" -> :awaiting_orchestrator
      "awaiting" -> :awaiting_orchestrator
      "completed" -> :completed
      "failed" -> :failed
      "timeout" -> :timeout
      _ -> :unknown
    end
  end

  defp live_sub_agent_snapshot(agent_id) when is_binary(agent_id) do
    case SubAgent.get_status(agent_id) do
      {:ok, %{} = status} ->
        %{
          status: status[:status],
          result: status[:result],
          tool_calls_used: status[:tool_calls_used],
          duration_ms: status[:duration_ms],
          reason: status[:reason],
          partial_history: status[:partial_history]
        }

      {:error, :not_found} ->
        nil
    end
  end

  defp live_sub_agent_snapshot(_), do: nil

  defp ensure_engine_started(user_id, conversation_id) do
    case Engine.get_state(user_id) do
      {:ok, _state} ->
        :ok

      {:error, :not_found} ->
        start_engine(user_id, conversation_id)
    end
  end

  defp start_engine(user_id, conversation_id) do
    opts = [
      user_id: user_id,
      conversation_id: conversation_id,
      channel: "settings",
      mode: :multi_agent
    ]

    child_spec = %{
      id: user_id,
      start: {Engine, :start_link, [user_id, opts]},
      restart: :temporary
    }

    case DynamicSupervisor.start_child(Assistant.Orchestrator.ConversationSupervisor, child_spec) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp in_app_message_metadata do
    %{
      "source" => %{
        "kind" => "in_app",
        "channel" => "in_app"
      }
    }
  end

  defp map_value(map, key) when is_map(map) and is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp map_value(_map, _key), do: nil

  defp normalize_text(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
    |> case do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_text(_value), do: nil

  defp titleize(value) when is_binary(value) do
    value
    |> String.replace("_", " ")
    |> String.split(" ", trim: true)
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(value), do: not is_nil(value)
end
