# lib/assistant/memory/file_cache.ex — Creates memory entries from file reads.
#
# Summarizes file content via LLM, generates search_queries, and persists as
# a memory entry with source_type "system" and category "file_cache".
#
# Related files:
#   - lib/assistant/memory/file_cache_worker.ex (Oban worker, enqueues async)
#   - lib/assistant/orchestrator/context_files.ex (hook site for file loads)
#   - lib/assistant/memory/store.ex (persistence layer)

defmodule Assistant.Memory.FileCache do
  @moduledoc false

  alias Assistant.Config.Loader, as: ConfigLoader
  alias Assistant.Integrations.LLMRouter
  alias Assistant.Memory.{Search, Store}
  alias Assistant.Repo
  alias Assistant.Schemas.MemoryEntry

  require Logger

  @max_content_for_summary 12_000
  @file_cache_tag "file_cache"
  @default_importance "0.60"

  @doc """
  Caches a file's content as a memory entry with generated search_queries.

  Runs an LLM call to produce a summary and 5-8 hypothetical search queries.
  Deduplicates by checking for an existing memory with the same file path tag.

  Returns `{:ok, entry}`, `{:ok, :already_cached}`, or `{:error, reason}`.
  """
  @spec cache_file(binary(), String.t(), String.t(), keyword()) ::
          {:ok, MemoryEntry.t() | :already_cached} | {:error, term()}
  def cache_file(user_id, file_path, content, _opts \\ []) do
    content_hash = content_hash(content)
    file_tag = "file:#{file_path}"

    case find_existing(user_id, file_tag) do
      {:ok, existing} ->
        if existing.metadata["content_hash"] == content_hash do
          {:ok, :already_cached}
        else
          update_existing(existing, content, content_hash)
        end

      :not_found ->
        create_new(user_id, file_path, file_tag, content, content_hash)
    end
  end

  # --- Lookup ---

  defp find_existing(user_id, file_tag) do
    case Search.search_by_tags(user_id, [file_tag]) do
      {:ok, [entry | _]} -> {:ok, entry}
      {:ok, []} -> :not_found
    end
  end

  # --- Create ---

  defp create_new(user_id, file_path, file_tag, content, content_hash) do
    with {:ok, model} <- resolve_model(user_id),
         {:ok, %{summary: summary, search_queries: queries}} <-
           summarize_file(model, file_path, content, user_id) do
      attrs = %{
        user_id: user_id,
        content: summary,
        source_type: "system",
        category: "file_cache",
        importance: Decimal.new(@default_importance),
        tags: [@file_cache_tag, file_tag],
        search_queries: queries,
        metadata: %{"file_path" => file_path, "content_hash" => content_hash}
      }

      Store.create_memory_entry(attrs)
    end
  end

  # --- Update ---

  defp update_existing(existing, content, content_hash) do
    user_id = existing.user_id
    file_path = existing.metadata["file_path"]

    with {:ok, model} <- resolve_model(user_id),
         {:ok, %{summary: summary, search_queries: queries}} <-
           summarize_file(model, file_path, content, user_id) do
      existing
      |> MemoryEntry.changeset(%{
        content: summary,
        search_queries: queries,
        metadata: Map.put(existing.metadata || %{}, "content_hash", content_hash)
      })
      |> Repo.update()
    end
  end

  # --- LLM ---

  defp resolve_model(user_id) do
    case ConfigLoader.model_for(:compaction, user_id: user_id) do
      nil -> {:error, :no_compaction_model}
      model -> {:ok, model}
    end
  end

  defp summarize_file(model, file_path, content, user_id) do
    truncated = String.slice(content, 0, @max_content_for_summary)

    messages = [
      %{
        role: "system",
        content: """
        You are a file summarizer. Given a file's path and content, produce a JSON object with:
        - "summary": A concise summary of the file (100-200 words). Include key facts, \
        function names, configuration values, and important details.
        - "search_queries": An array of 5-8 natural-language questions this file's content \
        would answer. Think about what someone might ask when they need information from this file.

        Respond with ONLY the JSON object, no markdown fencing.
        """
      },
      %{
        role: "user",
        content: """
        File: #{file_path}

        Content:
        #{truncated}
        """
      }
    ]

    opts = [
      model: model.id,
      temperature: 0.3,
      max_tokens: 1024
    ]

    case LLMRouter.chat_completion(messages, opts, user_id) do
      {:ok, response} ->
        parse_summary_response(response.content)

      {:error, reason} ->
        Logger.error("FileCache LLM call failed",
          file_path: file_path,
          reason: inspect(reason)
        )

        {:error, {:llm_call_failed, reason}}
    end
  end

  defp parse_summary_response(nil), do: {:error, :empty_llm_response}

  defp parse_summary_response(content) do
    # Strip potential markdown fencing
    cleaned =
      content
      |> String.replace(~r/^```json\s*/, "")
      |> String.replace(~r/\s*```$/, "")
      |> String.trim()

    case Jason.decode(cleaned) do
      {:ok, %{"summary" => summary, "search_queries" => queries}}
      when is_binary(summary) and is_list(queries) ->
        {:ok, %{summary: summary, search_queries: queries}}

      {:ok, _} ->
        {:error, :invalid_response_format}

      {:error, _} ->
        # LLM may have returned plain text instead of JSON — use as summary
        {:ok, %{summary: cleaned, search_queries: []}}
    end
  end

  # --- Helpers ---

  defp content_hash(content) do
    :crypto.hash(:sha256, content) |> Base.encode16(case: :lower) |> String.slice(0, 16)
  end
end
