defmodule Assistant.Transcripts do
  @moduledoc """
  Query layer for conversation/task transcripts in the settings UI.
  """

  import Ecto.Query

  alias Assistant.Encryption.BlindIndex
  alias Assistant.Messages.Content, as: MessageContent
  alias Assistant.Repo
  alias Assistant.Schemas.{Conversation, Message, Task, TaskHistory}

  @default_limit 50
  @default_message_limit 400
  @hosted_preview_placeholder "Preview unavailable in hosted mode"

  @spec list_transcripts(keyword()) :: [map()]
  def list_transcripts(opts \\ []) do
    limit = Keyword.get(opts, :limit, @default_limit)
    query = normalize_text(Keyword.get(opts, :query, ""))
    channel = normalize_text(Keyword.get(opts, :channel, ""))
    status = normalize_text(Keyword.get(opts, :status, ""))
    agent_type = normalize_text(Keyword.get(opts, :agent_type, ""))
    since = Keyword.get(opts, :since)

    conversation_query =
      conversation_listing_query()
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
          |> then(&MessageContent.hydrate_for_conversation!(conversation_id, &1))
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
    # Always allow searching by conversation ID prefix
    id_pattern = "%#{query}%"
    id_matches = where(queryable, [c], fragment("CAST(? AS text) ILIKE ?", c.id, ^id_pattern))

    # Also search via blind keyword index on message content
    case search_conversations_by_blind_index(query) do
      {:ok, []} ->
        id_matches

      {:ok, conversation_ids} ->
        # Union: conversations matching by ID OR by message content
        where(queryable, [c],
          fragment("CAST(? AS text) ILIKE ?", c.id, ^id_pattern) or c.id in ^conversation_ids
        )
    end
  end

  # Searches content_terms for messages matching the query text, then maps
  # the matching message IDs back to their conversation IDs.
  defp search_conversations_by_blind_index(query_text) do
    # We need a billing_account_id to generate digests. Since transcripts are
    # an admin/settings view, we derive it from conversations' users. For now,
    # generate digests using all known billing accounts that have indexed content.
    # In practice, the settings UI is scoped to one org, so there's typically
    # one billing_account_id.
    case get_billing_account_id_for_index() do
      nil ->
        {:ok, []}

      billing_account_id ->
        case BlindIndex.matching_owner_ids(query_text, billing_account_id, "message") do
          {:ok, []} ->
            {:ok, []}

          {:ok, message_ids} ->
            conversation_ids =
              from(m in Message,
                where: m.id in ^message_ids,
                select: m.conversation_id,
                distinct: true
              )
              |> Repo.all()

            {:ok, conversation_ids}
        end
    end
  end

  # Returns the billing_account_id to use for blind index digest generation.
  # Falls back to "local" for self-hosted instances without billing accounts.
  defp get_billing_account_id_for_index do
    if MessageContent.hosted_vault_transit_mode?() do
      # In hosted mode, look up a billing_account_id from the first conversation's user.
      # All users in a hosted instance share the same billing account.
      from(c in Conversation,
        join: u in assoc(c, :user),
        where: not is_nil(u.billing_account_id),
        select: u.billing_account_id,
        limit: 1
      )
      |> Repo.one()
    else
      "local"
    end
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

  defp conversation_listing_query do
    if hosted_vault_transit_mode?() do
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
          preview: ^@hosted_preview_placeholder
        }
      )
    else
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
          preview: ""
        }
      )
    end
  end

  defp hosted_vault_transit_mode? do
    MessageContent.hosted_vault_transit_mode?()
  end

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
