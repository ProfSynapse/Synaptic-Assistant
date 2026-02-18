# lib/assistant/memory/context_builder.ex — Assembles memory and task context
# for injection into orchestrator LLM prompts.
#
# Fetches conversation summary, relevant memories, and active tasks, then
# formats them into ~500-token-budget strings for the context block.
#
# Related files:
#   - lib/assistant/memory/store.ex (conversation + memory entry CRUD)
#   - lib/assistant/memory/search.ex (FTS retrieval)
#   - lib/assistant/task_manager/queries.ex (task listing)
#   - lib/assistant/orchestrator/context.ex (consumer — build_context_block)

defmodule Assistant.Memory.ContextBuilder do
  @moduledoc """
  Builds formatted memory and task context strings for LLM injection.

  Called by `Orchestrator.Context.build_context_block/2` when the caller
  does not provide pre-built `:memory_context` or `:task_summary` opts.

  ## Token Budgets

  Each section targets ~500 tokens (~2000 characters). If source data exceeds
  the budget, it is truncated with an indicator.

  ## Graceful Degradation

  If any data source fails (conversation not found, search error, DB timeout),
  that section returns an empty string rather than crashing the context build.
  """

  alias Assistant.Memory.{Search, Store}
  alias Assistant.TaskManager.Queries, as: TaskQueries

  require Logger

  # ~500 tokens at ~4 chars/token
  @memory_char_budget 2000
  @task_char_budget 2000

  @doc """
  Builds memory and task context strings for the orchestrator.

  ## Parameters

    * `conversation_id` - Current conversation UUID (may be nil for new conversations)
    * `user_id` - Current user UUID
    * `opts` - Optional overrides:
      * `:query` - Text query for memory search (defaults to conversation summary or empty)
      * `:memory_limit` - Max memory entries to retrieve (default: 5)
      * `:task_limit` - Max tasks to include (default: 5)

  ## Returns

    * `{:ok, %{memory_context: String.t(), task_summary: String.t()}}`

  Both strings may be empty if no relevant data exists.
  """
  @spec build_context(binary() | nil, binary(), keyword()) ::
          {:ok, %{memory_context: String.t(), task_summary: String.t()}}
  def build_context(conversation_id, user_id, opts \\ []) do
    memory_context = build_memory_section(conversation_id, user_id, opts)
    task_summary = build_task_section(user_id, opts)

    {:ok, %{memory_context: memory_context, task_summary: task_summary}}
  end

  # ---------------------------------------------------------------------------
  # Memory Section
  # ---------------------------------------------------------------------------

  defp build_memory_section(conversation_id, user_id, opts) do
    summary = fetch_conversation_summary(conversation_id)
    query = Keyword.get(opts, :query) || summary_as_query(summary)
    memory_limit = Keyword.get(opts, :memory_limit, 5)

    memories = fetch_relevant_memories(user_id, query, memory_limit)

    format_memory_context(summary, memories)
  end

  defp fetch_conversation_summary(nil), do: nil

  defp fetch_conversation_summary(conversation_id) do
    case Store.get_conversation(conversation_id) do
      {:ok, conversation} ->
        conversation.summary

      {:error, reason} ->
        Logger.debug("ContextBuilder: conversation lookup failed",
          conversation_id: conversation_id,
          reason: inspect(reason)
        )

        nil
    end
  end

  defp summary_as_query(nil), do: nil
  defp summary_as_query(""), do: nil
  defp summary_as_query(summary), do: summary

  defp fetch_relevant_memories(_user_id, nil, _limit), do: []

  defp fetch_relevant_memories(user_id, query, limit) do
    {:ok, entries} = Search.search_memories(user_id, query: query, limit: limit)
    entries
  rescue
    error ->
      Logger.debug("ContextBuilder: memory search failed",
        reason: Exception.message(error)
      )

      []
  end

  defp format_memory_context(nil, []), do: ""
  defp format_memory_context("", []), do: ""

  defp format_memory_context(summary, memories) do
    parts = []

    parts =
      if summary && summary != "" do
        parts ++ ["## Conversation Summary\n#{summary}"]
      else
        parts
      end

    parts =
      if memories != [] do
        formatted =
          memories
          |> Enum.with_index(1)
          |> Enum.map(fn {entry, idx} ->
            tags_str =
              case entry.tags do
                [] -> ""
                nil -> ""
                tags -> " [#{Enum.join(tags, ", ")}]"
              end

            "#{idx}. #{entry.content}#{tags_str}"
          end)
          |> Enum.join("\n")

        parts ++ ["## Relevant Memories\n#{formatted}"]
      else
        parts
      end

    result = Enum.join(parts, "\n\n")
    truncate_to_budget(result, @memory_char_budget)
  end

  # ---------------------------------------------------------------------------
  # Task Section
  # ---------------------------------------------------------------------------

  defp build_task_section(user_id, opts) do
    task_limit = Keyword.get(opts, :task_limit, 5)
    tasks = fetch_active_tasks(user_id, task_limit)
    format_task_summary(tasks)
  end

  defp fetch_active_tasks(user_id, limit) do
    # Fetch non-done, non-cancelled tasks that are not archived.
    # TaskManager.Queries.list_tasks requires user_id for ownership scoping.
    TaskQueries.list_tasks(
      user_id: user_id,
      assignee_id: user_id,
      include_archived: false,
      limit: limit,
      sort_by: :priority,
      sort_order: :asc
    )
  rescue
    error ->
      Logger.debug("ContextBuilder: task fetch failed",
        reason: inspect(error)
      )

      []
  end

  defp format_task_summary([]), do: ""

  defp format_task_summary(tasks) do
    formatted =
      tasks
      |> Enum.map(fn task ->
        status = task.status || "todo"
        priority = task.priority || "medium"
        due = if task.due_date, do: " due:#{Date.to_iso8601(task.due_date)}", else: ""
        "- [#{status}] #{task.short_id}: #{task.title} (#{priority}#{due})"
      end)
      |> Enum.join("\n")

    result = "## Active Tasks\n#{formatted}"
    truncate_to_budget(result, @task_char_budget)
  end

  # ---------------------------------------------------------------------------
  # Private Helpers
  # ---------------------------------------------------------------------------

  defp truncate_to_budget(text, max_chars) do
    if String.length(text) <= max_chars do
      text
    else
      # Leave room for the truncation indicator
      limit = max_chars - 20
      String.slice(text, 0, limit) <> "\n...[truncated]"
    end
  end
end
