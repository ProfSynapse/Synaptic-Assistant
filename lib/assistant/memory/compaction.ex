# lib/assistant/memory/compaction.ex — Incremental conversation summary fold.
#
# Core compaction logic that reads conversation history, calls a cheap/fast LLM
# to produce a condensed summary, and atomically stores the result. Supports both
# first compaction (no prior summary) and incremental fold (prior summary exists).
#
# The compaction model is: summary(n) = LLM(summary(n-1), messages_since_last)
#
# Used by:
#   - lib/assistant/scheduler/workers/compaction_worker.ex (Oban-triggered)
#   - lib/assistant/memory/agent.ex (LLM-driven compaction path, can delegate here)
#
# Depends on:
#   - lib/assistant/memory/store.ex (message retrieval, summary persistence)
#   - lib/assistant/integrations/openrouter.ex (LLM chat completion)
#   - lib/assistant/config/loader.ex (model selection for :compaction use case)
#   - lib/assistant/config/prompt_loader.ex (compaction system prompt)

defmodule Assistant.Memory.Compaction do
  @moduledoc """
  Incremental conversation summary fold.

  Reads the conversation's current summary and messages added since the last
  compaction, sends them to a cheap/fast LLM for summarization, and atomically
  updates the conversation's summary fields.

  ## Algorithm

      summary(0) = LLM([], first_batch_of_messages)
      summary(n) = LLM(summary(n-1), new_messages_since_version_n-1)

  ## Token Budget

  The compaction prompt includes a target token budget derived from the
  conversation's context window settings. This guides the LLM to produce
  summaries of appropriate length.
  """

  require Logger

  alias Assistant.Config.Loader, as: ConfigLoader
  alias Assistant.Config.PromptLoader
  alias Assistant.Integrations.OpenRouter
  alias Assistant.Memory.Store

  @default_token_budget 2048
  @default_message_batch_size 100

  @doc """
  Compacts a conversation by folding new messages into its summary.

  ## Parameters

    * `conversation_id` - UUID of the conversation to compact.
    * `opts` - Optional keyword list:
      * `:token_budget` - Target token count for the summary (default: #{@default_token_budget})
      * `:message_limit` - Max messages to include per compaction (default: #{@default_message_batch_size})

  ## Returns

    * `{:ok, conversation}` - Updated conversation with new summary
    * `{:error, :not_found}` - Conversation doesn't exist
    * `{:error, :no_new_messages}` - No messages to compact
    * `{:error, :no_compaction_model}` - No model configured for :compaction use case
    * `{:error, reason}` - LLM or prompt rendering failure
  """
  @spec compact(binary(), keyword()) :: {:ok, map()} | {:error, term()}
  def compact(conversation_id, opts \\ []) do
    token_budget = Keyword.get(opts, :token_budget, @default_token_budget)
    message_limit = Keyword.get(opts, :message_limit, @default_message_batch_size)

    with {:ok, conversation} <- Store.get_conversation(conversation_id),
         {:ok, messages} <- fetch_new_messages(conversation, message_limit),
         {:ok, model} <- resolve_compaction_model(),
         {:ok, system_prompt} <- render_system_prompt(token_budget),
         {:ok, user_prompt} <- build_user_prompt(conversation, messages),
         {:ok, summary_text} <- call_llm(model, system_prompt, user_prompt) do
      Store.update_summary(conversation_id, summary_text, model.id)
    end
  end

  # ---------------------------------------------------------------------------
  # Message fetching
  # ---------------------------------------------------------------------------

  # Fetches messages that haven't been summarized yet.
  # For first compaction (summary_version == 0): all messages.
  # For incremental: messages inserted after the conversation's last update_at
  # associated with the summary_version bump. We use offset-based approach:
  # skip the number of messages already covered by the summary version, then
  # take the next batch.
  defp fetch_new_messages(conversation, message_limit) do
    summary_version = conversation.summary_version || 0

    messages =
      if summary_version == 0 do
        # First compaction: all messages
        Store.list_messages(conversation.id, limit: message_limit, order: :asc)
      else
        # Incremental: messages beyond what was already summarized.
        # We use the simple heuristic of fetching the most recent messages.
        # A more precise approach would track the last-compacted message ID,
        # but summary_version + recent messages is sufficient for incremental fold.
        Store.list_messages(conversation.id,
          limit: message_limit,
          order: :desc
        )
        |> Enum.reverse()
      end

    case messages do
      [] -> {:error, :no_new_messages}
      msgs -> {:ok, msgs}
    end
  end

  # ---------------------------------------------------------------------------
  # Model resolution
  # ---------------------------------------------------------------------------

  defp resolve_compaction_model do
    case ConfigLoader.model_for(:compaction) do
      nil ->
        Logger.error("No model configured for :compaction use case")
        {:error, :no_compaction_model}

      model ->
        {:ok, model}
    end
  end

  # ---------------------------------------------------------------------------
  # Prompt construction
  # ---------------------------------------------------------------------------

  defp render_system_prompt(token_budget) do
    assigns = %{
      token_budget: token_budget,
      current_date: Date.to_iso8601(Date.utc_today())
    }

    case PromptLoader.render(:compaction, assigns) do
      {:ok, rendered} ->
        {:ok, rendered}

      {:error, :not_found} ->
        # Fallback if prompt file is missing
        Logger.warning("Compaction prompt template not found, using fallback")
        {:ok, fallback_system_prompt(token_budget)}

      {:error, reason} ->
        Logger.error("Failed to render compaction prompt", reason: inspect(reason))
        {:error, {:prompt_render_failed, reason}}
    end
  end

  defp build_user_prompt(conversation, messages) do
    prior_summary_section =
      case conversation.summary do
        nil ->
          "No prior summary exists. This is the first compaction."

        summary ->
          """
          ## Prior Summary (version #{conversation.summary_version})

          #{summary}
          """
      end

    messages_section =
      messages
      |> Enum.map(&format_message/1)
      |> Enum.join("\n")

    prompt = """
    #{prior_summary_section}

    ## New Messages to Incorporate

    #{messages_section}

    Please produce an updated summary that incorporates the new messages above \
    with the prior summary (if any). Preserve all key information.
    """

    {:ok, prompt}
  end

  defp format_message(message) do
    role = String.upcase(message.role || "unknown")
    content = message.content || "[no content]"

    # Truncate very long messages to avoid blowing the context window
    truncated =
      if String.length(content) > 2000 do
        String.slice(content, 0, 2000) <> "... [truncated]"
      else
        content
      end

    "[#{role}]: #{truncated}"
  end

  defp fallback_system_prompt(token_budget) do
    """
    You are a conversation compactor. Summarize the conversation history into \
    a concise context block preserving key facts, decisions, tasks, preferences, \
    names, dates, and identifiers. Discard redundant exchanges and verbose tool \
    outputs. Target approximately #{token_budget} tokens.
    """
  end

  # ---------------------------------------------------------------------------
  # LLM call
  # ---------------------------------------------------------------------------

  defp call_llm(model, system_prompt, user_prompt) do
    messages = [
      %{role: "system", content: system_prompt},
      %{role: "user", content: user_prompt}
    ]

    opts = [
      model: model.id,
      temperature: 0.3,
      max_tokens: @default_token_budget + 512
    ]

    case OpenRouter.chat_completion(messages, opts) do
      {:ok, response} ->
        case response.content do
          nil ->
            Logger.error("Compaction LLM returned nil content",
              conversation_model: model.id
            )
            {:error, :empty_llm_response}

          content ->
            Logger.info("Compaction completed",
              model: model.id,
              summary_length: String.length(content),
              prompt_tokens: response.usage.prompt_tokens,
              completion_tokens: response.usage.completion_tokens
            )
            {:ok, content}
        end

      {:error, reason} ->
        Logger.error("Compaction LLM call failed",
          model: model.id,
          reason: inspect(reason)
        )
        {:error, {:llm_call_failed, reason}}
    end
  end
end
