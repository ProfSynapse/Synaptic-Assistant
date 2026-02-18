# lib/assistant/memory/store.ex — Persistence layer for conversations, messages,
# and memory entries.
#
# Provides CRUD operations used by the memory system (compaction, context
# builder, memory skills) and the orchestrator (conversation lifecycle).
# All functions return {:ok, result} | {:error, reason} for consistent
# error handling.
#
# Related files:
#   - lib/assistant/schemas/conversation.ex (Conversation schema)
#   - lib/assistant/schemas/message.ex (Message schema)
#   - lib/assistant/schemas/memory_entry.ex (MemoryEntry schema)
#   - lib/assistant/schemas/memory_entity_mention.ex (mention join table)
#   - lib/assistant/repo.ex (Ecto repository)
#   - lib/assistant/memory/search.ex (FTS + hybrid retrieval — Wave 2)
#   - lib/assistant/memory/context_builder.ex (context assembly — Wave 4)

defmodule Assistant.Memory.Store do
  @moduledoc """
  Persistence layer for conversations, messages, and memory entries.

  This module is the single gateway for all database reads and writes in the
  memory subsystem. It wraps `Assistant.Repo` with domain-specific query
  logic and ensures atomic multi-step operations via `Ecto.Multi`.

  ## Scope

  - Conversation CRUD and summary updates (for compaction)
  - Message insertion and paginated retrieval
  - Memory entry CRUD with entity mention preloading

  Full-text search lives in `Assistant.Memory.Search` (Wave 2).
  Context assembly lives in `Assistant.Memory.ContextBuilder` (Wave 4).
  """

  import Ecto.Query

  alias Assistant.Repo
  alias Assistant.Schemas.{Conversation, MemoryEntry, Message}

  # ---------------------------------------------------------------------------
  # Conversations
  # ---------------------------------------------------------------------------

  @doc """
  Creates a new conversation from the given attributes.

  ## Parameters

    * `attrs` - Map with at least `:channel` and `:user_id`.

  ## Returns

    * `{:ok, %Conversation{}}` on success
    * `{:error, %Ecto.Changeset{}}` on validation failure
  """
  @spec create_conversation(map()) :: {:ok, Conversation.t()} | {:error, Ecto.Changeset.t()}
  def create_conversation(attrs) do
    %Conversation{}
    |> Conversation.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Fetches a conversation by its ID.

  ## Returns

    * `{:ok, %Conversation{}}` if found
    * `{:error, :not_found}` if no conversation exists with that ID
  """
  @spec get_conversation(binary()) :: {:ok, Conversation.t()} | {:error, :not_found}
  def get_conversation(id) do
    case Repo.get(Conversation, id) do
      nil -> {:error, :not_found}
      conv -> {:ok, conv}
    end
  end

  @doc """
  Finds an existing active conversation for the user or creates a new one.

  Looks up the most recent active conversation for `user_id`. If none exists,
  inserts a new one using `attrs` (which must include `:channel`).

  ## Parameters

    * `user_id` - The user's binary ID.
    * `attrs` - Map of attributes for creation (must include `:channel`).

  ## Returns

    * `{:ok, %Conversation{}}` — existing or newly created conversation
    * `{:error, %Ecto.Changeset{}}` — if creation fails validation
  """
  @spec get_or_create_conversation(binary(), map()) ::
          {:ok, Conversation.t()} | {:error, Ecto.Changeset.t()}
  def get_or_create_conversation(user_id, attrs) do
    query =
      from c in Conversation,
        where: c.user_id == ^user_id and c.status == "active",
        order_by: [desc: c.last_active_at, desc: c.inserted_at],
        limit: 1

    case Repo.one(query) do
      nil ->
        create_conversation(Map.put(attrs, :user_id, user_id))

      conversation ->
        {:ok, conversation}
    end
  end

  # ---------------------------------------------------------------------------
  # Messages
  # ---------------------------------------------------------------------------

  @doc """
  Appends a message to a conversation.

  Sets `conversation_id` on the message attrs and touches the conversation's
  `last_active_at` timestamp atomically.

  ## Parameters

    * `conversation_id` - The conversation to append to.
    * `attrs` - Message attributes (`:role` is required, `:content` etc. optional).

  ## Returns

    * `{:ok, %Message{}}` on success
    * `{:error, reason}` on failure (changeset error or missing conversation)
  """
  @spec append_message(binary(), map()) :: {:ok, Message.t()} | {:error, term()}
  def append_message(conversation_id, attrs) do
    now = DateTime.utc_now()
    message_attrs = Map.put(attrs, :conversation_id, conversation_id)

    Ecto.Multi.new()
    |> Ecto.Multi.insert(:message, Message.changeset(%Message{}, message_attrs))
    |> Ecto.Multi.update_all(
      :touch_conversation,
      from(c in Conversation, where: c.id == ^conversation_id),
      set: [last_active_at: now]
    )
    |> Repo.transaction()
    |> case do
      {:ok, %{message: message}} -> {:ok, message}
      {:error, :message, changeset, _changes} -> {:error, changeset}
    end
  end

  @doc """
  Lists messages for a conversation with pagination support.

  ## Parameters

    * `conversation_id` - The conversation to list messages for.
    * `opts` - Keyword list of options:
      * `:limit` - Max messages to return (default: 50)
      * `:offset` - Number of messages to skip (default: 0)
      * `:order` - `:asc` or `:desc` by `inserted_at` (default: `:asc`)

  ## Returns

    * List of `%Message{}` structs (may be empty)
  """
  @spec list_messages(binary(), keyword()) :: [Message.t()]
  def list_messages(conversation_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    offset = Keyword.get(opts, :offset, 0)
    order = Keyword.get(opts, :order, :asc)

    direction = if order == :desc, do: :desc, else: :asc

    from(m in Message,
      where: m.conversation_id == ^conversation_id,
      order_by: [{^direction, m.inserted_at}],
      limit: ^limit,
      offset: ^offset
    )
    |> Repo.all()
  end

  @doc """
  Fetches messages within a range of message IDs (inclusive).

  Used by the compaction system to retrieve the message window that needs
  summarization. Returns messages ordered by `inserted_at` ascending.

  ## Parameters

    * `conversation_id` - The conversation to query.
    * `start_message_id` - First message ID in the range (inclusive).
    * `end_message_id` - Last message ID in the range (inclusive).

  ## Returns

    * List of `%Message{}` structs in chronological order
  """
  @spec get_messages_in_range(binary(), binary(), binary()) :: [Message.t()]
  def get_messages_in_range(conversation_id, start_message_id, end_message_id) do
    # Fetch the timestamps for the boundary messages, then select all messages
    # in that time range. This avoids UUID comparison issues since UUIDs are
    # not sequentially ordered.
    boundary_query =
      from m in Message,
        where:
          m.conversation_id == ^conversation_id and
            m.id in [^start_message_id, ^end_message_id],
        select: {m.id, m.inserted_at}

    boundaries = Repo.all(boundary_query) |> Map.new()

    case {Map.get(boundaries, start_message_id), Map.get(boundaries, end_message_id)} do
      {nil, _} ->
        []

      {_, nil} ->
        []

      {start_at, end_at} ->
        from(m in Message,
          where:
            m.conversation_id == ^conversation_id and
              m.inserted_at >= ^start_at and
              m.inserted_at <= ^end_at,
          order_by: [asc: m.inserted_at]
        )
        |> Repo.all()
    end
  end

  # ---------------------------------------------------------------------------
  # Conversation Summary (Compaction)
  # ---------------------------------------------------------------------------

  @doc """
  Atomically updates a conversation's summary and increments its version.

  Uses `Ecto.Multi` to ensure the summary text, version increment, and model
  name are applied together. The version increment is a DB-level operation
  to avoid race conditions with concurrent compaction.

  ## Parameters

    * `conversation_id` - The conversation to update.
    * `summary_text` - The new summary content.
    * `model_name` - The model used to generate the summary.

  ## Returns

    * `{:ok, %Conversation{}}` with updated fields
    * `{:error, :not_found}` if conversation doesn't exist
    * `{:error, reason}` on other failures
  """
  @spec update_summary(binary(), String.t(), String.t()) ::
          {:ok, Conversation.t()} | {:error, term()}
  def update_summary(conversation_id, summary_text, model_name) do
    Ecto.Multi.new()
    |> Ecto.Multi.update_all(
      :update_summary,
      from(c in Conversation,
        where: c.id == ^conversation_id,
        select: c
      ),
      set: [
        summary: summary_text,
        summary_model: model_name,
        updated_at: DateTime.utc_now()
      ],
      inc: [summary_version: 1]
    )
    |> Repo.transaction()
    |> case do
      {:ok, %{update_summary: {0, _}}} ->
        {:error, :not_found}

      {:ok, %{update_summary: {1, [conversation]}}} ->
        {:ok, conversation}

      {:ok, %{update_summary: {_count, [conversation | _]}}} ->
        {:ok, conversation}

      {:error, _operation, reason, _changes} ->
        {:error, reason}
    end
  end

  # ---------------------------------------------------------------------------
  # Memory Entries
  # ---------------------------------------------------------------------------

  @doc """
  Creates a new memory entry.

  ## Parameters

    * `attrs` - Map with at least `:content`. Optional: `:tags`, `:category`,
      `:source_type`, `:importance`, `:user_id`, `:source_conversation_id`,
      `:segment_start_message_id`, `:segment_end_message_id`.

  ## Returns

    * `{:ok, %MemoryEntry{}}` on success
    * `{:error, %Ecto.Changeset{}}` on validation failure
  """
  @spec create_memory_entry(map()) :: {:ok, MemoryEntry.t()} | {:error, Ecto.Changeset.t()}
  def create_memory_entry(attrs) do
    %MemoryEntry{}
    |> MemoryEntry.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Fetches a memory entry by ID with preloaded entity mentions.

  ## Returns

    * `{:ok, %MemoryEntry{}}` with `entity_mentions` preloaded
    * `{:error, :not_found}` if no entry exists with that ID
  """
  @spec get_memory_entry(binary()) :: {:ok, MemoryEntry.t()} | {:error, :not_found}
  def get_memory_entry(id) do
    case Repo.get(MemoryEntry, id) do
      nil ->
        {:error, :not_found}

      entry ->
        {:ok, Repo.preload(entry, :entity_mentions)}
    end
  end

  @doc """
  Touches the `accessed_at` timestamp on a memory entry.

  Used by the retrieval system to track when a memory was last accessed,
  which feeds into the decay/importance scoring.

  ## Returns

    * `{:ok, %MemoryEntry{}}` with updated `accessed_at`
    * `{:error, :not_found}` if entry doesn't exist
  """
  @spec update_memory_entry_accessed_at(binary()) ::
          {:ok, MemoryEntry.t()} | {:error, :not_found}
  def update_memory_entry_accessed_at(id) do
    now = DateTime.utc_now()

    from(me in MemoryEntry,
      where: me.id == ^id,
      select: me
    )
    |> Repo.update_all(set: [accessed_at: now])
    |> case do
      {0, _} -> {:error, :not_found}
      {_count, [entry]} -> {:ok, entry}
    end
  end

  @doc """
  Lists memory entries with optional filters.

  ## Parameters

    * `opts` - Keyword list of filters:
      * `:user_id` - Filter by user (strongly recommended for scoping)
      * `:category` - Filter by category string
      * `:importance_min` - Minimum importance threshold (Decimal or float)
      * `:limit` - Max entries to return (default: 20)
      * `:offset` - Number of entries to skip (default: 0)

  ## Returns

    * List of `%MemoryEntry{}` structs ordered by `inserted_at` descending
  """
  @spec list_memory_entries(keyword()) :: [MemoryEntry.t()]
  def list_memory_entries(opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)
    offset = Keyword.get(opts, :offset, 0)

    query = from(me in MemoryEntry, order_by: [desc: me.inserted_at])

    query = apply_memory_filters(query, opts)

    query
    |> limit(^limit)
    |> offset(^offset)
    |> Repo.all()
  end

  # ---------------------------------------------------------------------------
  # Private Helpers
  # ---------------------------------------------------------------------------

  defp apply_memory_filters(query, opts) do
    query
    |> maybe_filter_by_user(Keyword.get(opts, :user_id))
    |> maybe_filter_by_category(Keyword.get(opts, :category))
    |> maybe_filter_by_importance(Keyword.get(opts, :importance_min))
  end

  defp maybe_filter_by_user(query, nil), do: query

  defp maybe_filter_by_user(query, user_id) do
    from me in query, where: me.user_id == ^user_id
  end

  defp maybe_filter_by_category(query, nil), do: query

  defp maybe_filter_by_category(query, category) do
    from me in query, where: me.category == ^category
  end

  defp maybe_filter_by_importance(query, nil), do: query

  defp maybe_filter_by_importance(query, importance_min) do
    min_decimal =
      case importance_min do
        %Decimal{} = d -> d
        f when is_float(f) -> Decimal.from_float(f)
        i when is_integer(i) -> Decimal.new(i)
      end

    from me in query, where: me.importance >= ^min_decimal
  end
end
