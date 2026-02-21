defmodule Assistant.Transcripts do
  @moduledoc """
  Query layer for conversation/task transcripts in the settings UI.
  """

  import Ecto.Query

  alias Assistant.Repo
  alias Assistant.Schemas.{Conversation, Message, Task, TaskHistory}

  @default_limit 50
  @default_message_limit 400

  @spec list_transcripts(keyword()) :: [map()]
  def list_transcripts(opts \\ []) do
    limit = Keyword.get(opts, :limit, @default_limit)
    query = normalize_text(Keyword.get(opts, :query, ""))
    channel = normalize_text(Keyword.get(opts, :channel, ""))
    status = normalize_text(Keyword.get(opts, :status, ""))
    agent_type = normalize_text(Keyword.get(opts, :agent_type, ""))
    since = Keyword.get(opts, :since)

    conversation_query =
      from(c in Conversation,
        as: :conversation,
        left_join: m in Message,
        on: m.conversation_id == c.id,
        group_by: [
          c.id,
          c.channel,
          c.status,
          c.agent_type,
          c.user_id,
          c.inserted_at,
          c.last_active_at
        ],
        select: %{
          id: c.id,
          channel: c.channel,
          status: c.status,
          agent_type: c.agent_type,
          user_id: c.user_id,
          inserted_at: c.inserted_at,
          last_active_at: c.last_active_at,
          message_count: count(m.id),
          last_message_at: max(m.inserted_at),
          preview:
            fragment(
              "COALESCE((SELECT m2.content FROM messages m2 WHERE m2.conversation_id = ? ORDER BY m2.inserted_at DESC LIMIT 1), '')",
              c.id
            )
        }
      )
      |> maybe_filter_channel(channel)
      |> maybe_filter_status(status)
      |> maybe_filter_agent_type(agent_type)
      |> maybe_filter_query(query)
      |> maybe_filter_since(since)
      |> order_by([c], desc: coalesce(c.last_active_at, c.inserted_at))
      |> limit(^limit)

    Repo.all(conversation_query)
    |> Enum.map(fn row ->
      Map.update!(row, :preview, &truncate_preview/1)
    end)
  end

  @spec get_transcript(String.t(), keyword()) :: {:ok, map()} | {:error, :not_found}
  def get_transcript(conversation_id, opts \\ []) do
    message_limit = Keyword.get(opts, :message_limit, @default_message_limit)

    case Repo.get(Conversation, conversation_id) do
      nil ->
        {:error, :not_found}

      conversation ->
        messages =
          from(m in Message,
            where: m.conversation_id == ^conversation_id,
            order_by: [asc: m.inserted_at],
            limit: ^message_limit
          )
          |> Repo.all()
          |> Enum.map(&map_message/1)

        related_tasks = related_tasks(conversation_id)

        {:ok,
         %{
           conversation: %{
             id: conversation.id,
             channel: conversation.channel,
             status: conversation.status,
             agent_type: conversation.agent_type,
             user_id: conversation.user_id,
             started_at: conversation.started_at,
             last_active_at: conversation.last_active_at,
             inserted_at: conversation.inserted_at
           },
           messages: messages,
           related_tasks: related_tasks
         }}
    end
  end

  @spec filter_options() :: %{
          channels: [String.t()],
          statuses: [String.t()],
          agent_types: [String.t()]
        }
  def filter_options do
    channels =
      from(c in Conversation,
        select: c.channel,
        where: not is_nil(c.channel),
        distinct: true,
        order_by: c.channel
      )
      |> Repo.all()
      |> Enum.reject(&(&1 in [nil, ""]))

    %{
      channels: channels,
      statuses: ~w(active idle closed),
      agent_types: ~w(orchestrator sub_agent)
    }
  end

  defp maybe_filter_query(queryable, ""), do: queryable

  defp maybe_filter_query(queryable, query) do
    pattern = "%#{query}%"

    where(
      queryable,
      [c],
      fragment("CAST(? AS text) ILIKE ?", c.id, ^pattern) or
        fragment(
          "EXISTS (SELECT 1 FROM messages m3 WHERE m3.conversation_id = ? AND COALESCE(m3.content, '') ILIKE ?)",
          c.id,
          ^pattern
        )
    )
  end

  defp maybe_filter_channel(queryable, ""), do: queryable
  defp maybe_filter_channel(queryable, channel), do: where(queryable, [c], c.channel == ^channel)

  defp maybe_filter_status(queryable, ""), do: queryable
  defp maybe_filter_status(queryable, status), do: where(queryable, [c], c.status == ^status)

  defp maybe_filter_agent_type(queryable, ""), do: queryable

  defp maybe_filter_agent_type(queryable, agent_type),
    do: where(queryable, [c], c.agent_type == ^agent_type)

  defp maybe_filter_since(queryable, nil), do: queryable

  defp maybe_filter_since(queryable, %DateTime{} = since) do
    where(
      queryable,
      [c],
      fragment("COALESCE(?, ?) >= ?", c.last_active_at, c.inserted_at, ^since)
    )
  end

  defp maybe_filter_since(queryable, _invalid), do: queryable

  defp map_message(message) do
    %{
      id: message.id,
      role: message.role,
      content: message.content,
      tool_calls: message.tool_calls,
      tool_results: message.tool_results,
      inserted_at: message.inserted_at
    }
  end

  defp related_tasks(conversation_id) do
    created_ids =
      from(t in Task,
        where: t.created_via_conversation_id == ^conversation_id,
        select: t.id
      )
      |> Repo.all()

    history_ids =
      from(h in TaskHistory,
        where: h.changed_via_conversation_id == ^conversation_id,
        select: h.task_id
      )
      |> Repo.all()

    task_ids = (created_ids ++ history_ids) |> Enum.uniq()

    if task_ids == [] do
      []
    else
      from(t in Task,
        where: t.id in ^task_ids,
        order_by: [desc: t.inserted_at],
        select: %{
          id: t.id,
          short_id: t.short_id,
          title: t.title,
          status: t.status,
          priority: t.priority,
          inserted_at: t.inserted_at
        }
      )
      |> Repo.all()
    end
  end

  defp truncate_preview(content) when is_binary(content) do
    content
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> String.slice(0, 140)
  end

  defp truncate_preview(_), do: ""

  defp normalize_text(value) when is_binary(value), do: String.trim(value)
  defp normalize_text(value) when is_atom(value), do: value |> Atom.to_string() |> String.trim()
  defp normalize_text(_), do: ""
end
