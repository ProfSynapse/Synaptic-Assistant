# lib/assistant/memory/prefetch.ex — Resolves context_questions before sub-agent execution.
#
# Each question runs as an FTS query against the user's memory store.
# Results are deduplicated and formatted for system prompt injection.
#
# Related files:
#   - lib/assistant/memory/search.ex (FTS engine)
#   - lib/assistant/orchestrator/sub_agent.ex (consumer — injects output into system prompt)
#   - lib/assistant/orchestrator/tools/dispatch_agent.ex (source of context_questions)

defmodule Assistant.Memory.Prefetch do
  @moduledoc """
  Resolves context_questions against the memory system before sub-agent
  execution. Each question runs as an FTS query; results are deduplicated
  and formatted for system prompt injection.
  """

  alias Assistant.Memory.Search

  @default_per_question_limit 3
  @max_total_results 10

  @doc """
  Runs each question as an FTS search against the user's memories.

  Returns a formatted string suitable for system prompt injection,
  or `""` if no results are found or no questions are provided.

  ## Parameters

    * `user_id` - The user whose memories to search.
    * `questions` - List of natural-language questions.
    * `opts` - Optional keyword list:
      * `:per_question_limit` - Max results per question (default: #{@default_per_question_limit})

  ## Returns

    * A formatted string with grouped results, or `""` if empty.
  """
  @spec resolve(binary(), [String.t()], keyword()) :: String.t()
  def resolve(user_id, questions, opts \\ [])
  def resolve(_user_id, [], _opts), do: ""
  def resolve(_user_id, nil, _opts), do: ""

  def resolve(user_id, questions, opts) do
    per_q_limit = Keyword.get(opts, :per_question_limit, @default_per_question_limit)

    results =
      questions
      |> Enum.flat_map(fn question ->
        case Search.search_memories(user_id, query: question, limit: per_q_limit) do
          {:ok, entries} ->
            Enum.map(entries, fn entry -> {question, entry} end)

          _ ->
            []
        end
      end)
      |> deduplicate_by_entry_id()
      |> Enum.take(@max_total_results)

    format_prefetch_context(results)
  end

  # Deduplicates {question, entry} tuples by entry.id, keeping the first
  # occurrence (i.e., the highest-ranked match from the first question
  # that returned it).
  defp deduplicate_by_entry_id(results) do
    results
    |> Enum.reduce({[], MapSet.new()}, fn {question, entry}, {acc, seen} ->
      if MapSet.member?(seen, entry.id) do
        {acc, seen}
      else
        {[{question, entry} | acc], MapSet.put(seen, entry.id)}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  defp format_prefetch_context([]), do: ""

  defp format_prefetch_context(results) do
    grouped =
      results
      |> Enum.group_by(fn {question, _entry} -> question end, fn {_question, entry} -> entry end)

    sections =
      Enum.map(grouped, fn {question, entries} ->
        items =
          Enum.map_join(entries, "\n", fn entry ->
            tags_suffix =
              case entry.tags do
                [] -> ""
                tags -> " [tags: #{Enum.join(tags, ", ")}]"
              end

            "- #{truncate_content(entry.content)}#{tags_suffix}"
          end)

        "> #{question}\n#{items}"
      end)

    "## Pre-fetched Memory Context\n\n" <> Enum.join(sections, "\n\n")
  end

  defp truncate_content(nil), do: "[no content]"

  defp truncate_content(content) do
    if String.length(content) > 300 do
      String.slice(content, 0, 300) <> "..."
    else
      content
    end
  end
end
