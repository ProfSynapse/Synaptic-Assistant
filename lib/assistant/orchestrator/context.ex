# lib/assistant/orchestrator/context.ex — Context assembly for orchestrator LLM calls.
#
# Builds cache-friendly message payloads for the orchestrator. The message
# structure is ordered for prompt caching: static prefix first (system prompt
# + tool defs) → cache breakpoint → dynamic messages (memory, history, user
# message). The orchestrator tools (get_skill, dispatch_agent, get_agent_results,
# send_agent_update) are compiled once as module attributes and never change at
# runtime.
#
# Related files:
#   - lib/assistant/integrations/openrouter.ex (cached_content helper)
#   - lib/assistant/orchestrator/tools/get_skill.ex (tool definition)
#   - lib/assistant/orchestrator/tools/dispatch_agent.ex (tool definition)
#   - lib/assistant/orchestrator/tools/get_agent_results.ex (tool definition)
#   - lib/assistant/orchestrator/tools/send_agent_update.ex (tool definition)
#   - lib/assistant/skills/registry.ex (domain listing)
#   - lib/assistant/config/loader.ex (model roster, limits config)
#   - lib/assistant/config/prompt_loader.ex (orchestrator system prompt template)

defmodule Assistant.Orchestrator.Context do
  @moduledoc """
  Context assembly for orchestrator LLM requests.

  Builds a cache-optimized message payload with two breakpoints:

    1. **System prompt** (1-hour TTL) — identity, rules, domain list
    2. **Context block** (5-min TTL) — memory, task summary, history prefix

  Dynamic content (current user message, tool results) follows the cached
  blocks. Tool definitions are compiled as module attributes for consistency.

  ## Cache Architecture

  The orchestrator's system prompt changes at most once per day (date rollover).
  With 1-hour TTL, every API call within an hour across all conversations
  hits this cache. The context block is stable within an agent loop iteration,
  providing cache hits on subsequent LLM calls within the same user turn.
  """

  alias Assistant.Config.Loader, as: ConfigLoader
  alias Assistant.Config.PromptLoader
  alias Assistant.Integrations.OpenRouter
  alias Assistant.Orchestrator.Tools.{DispatchAgent, GetAgentResults, GetSkill, SendAgentUpdate}
  alias Assistant.Skills.Registry

  require Logger

  # Approximate tokens per character for budget estimation.
  # ~4 chars per token is a reasonable heuristic across models.
  @chars_per_token 4

  # --- Tool Definitions (compiled once, never change at runtime) ---

  @doc """
  Returns the orchestrator's tool definitions in OpenAI function-call format.

  Tools are sorted alphabetically by name for consistent prompt caching.
  Compiled once at module load time.
  """
  @spec tool_definitions() :: [map()]
  def tool_definitions do
    [
      wrap_function_tool(DispatchAgent.tool_definition()),
      wrap_function_tool(GetAgentResults.tool_definition()),
      wrap_function_tool(GetSkill.tool_definition()),
      wrap_function_tool(SendAgentUpdate.tool_definition())
    ]
    |> OpenRouter.sort_tools()
  end

  # --- Context Assembly ---

  @doc """
  Builds a full LLM request context for the orchestrator.

  Returns a map with `:system`, `:messages`, and `:tools` keys suitable
  for passing to `LLMClient.chat_completion/2`.

  ## Parameters

    * `loop_state` - Current LoopState with conversation_id, user_id, channel
    * `messages` - Conversation message history (list of role/content maps)
    * `opts` - Optional overrides:
      * `:memory_context` - Pre-fetched memory text (skips retrieval)
      * `:task_summary` - Pre-fetched task summary (skips generation)

  ## Returns

  A map with keys:
    * `:system` - System prompt text (with cache_control breakpoint)
    * `:messages` - Ordered message list for the LLM
    * `:tools` - Tool definitions in OpenAI format
    * `:model` - Model ID to use (from loop_state or config default)
  """
  @spec build(map(), [map()], keyword()) :: map()
  def build(loop_state, messages, opts \\ []) do
    system_prompt = build_system_prompt(loop_state)
    context_block = build_context_block(loop_state, opts)

    role = loop_state[:role] || :orchestrator

    # Build cache-friendly message structure:
    # [system(1h cached)] + [context(5min cached) | dynamic messages]
    system_message = %{
      role: "system",
      content: [OpenRouter.cached_content(system_prompt, ttl: "1h")]
    }

    # Context block + conversation history in a single user message sequence
    context_and_messages = build_message_sequence(context_block, messages, role, loop_state)

    %{
      system: system_message,
      messages: context_and_messages,
      tools: tool_definitions()
    }
  end

  @doc """
  Builds just the system prompt text (without cache wrapping).

  Useful for sub-agent prompts that need a different caching strategy.
  """
  @spec build_system_prompt(map()) :: String.t()
  def build_system_prompt(loop_state) do
    domains = list_domains()

    assigns = %{
      skill_domains: Enum.join(domains, ", "),
      user_id: loop_state[:user_id] || "unknown",
      channel: loop_state[:channel] || "unknown",
      current_date: Date.utc_today() |> Date.to_iso8601()
    }

    case PromptLoader.render(:orchestrator, assigns) do
      {:ok, rendered} ->
        rendered

      {:error, _reason} ->
        # Fallback: hardcoded prompt if YAML not loaded
        Logger.warning("PromptLoader fallback for :orchestrator — using hardcoded prompt")

        """
        You are an AI assistant orchestrator. You coordinate sub-agents to fulfill user requests.

        Available skill domains: #{assigns.skill_domains}

        User: #{assigns.user_id}
        Channel: #{assigns.channel}
        Date: #{assigns.current_date}
        """
    end
  end

  # --- Private: System Prompt Components ---

  defp list_domains do
    Registry.list_domain_indexes()
    |> Enum.map(& &1.domain)
    |> Enum.sort()
  end

  # --- Private: Context Block ---

  defp build_context_block(_loop_state, opts) do
    memory = Keyword.get(opts, :memory_context, "")
    task_summary = Keyword.get(opts, :task_summary, "")

    parts =
      [memory, task_summary]
      |> Enum.reject(&(&1 == "" or is_nil(&1)))
      |> Enum.join("\n\n")

    if parts == "", do: nil, else: parts
  end

  # --- Private: Message Sequence ---

  defp build_message_sequence(context_block, messages, role, loop_state) do
    # If we have a context block, prepend it as a cached user message
    context_messages =
      if context_block do
        [
          %{
            role: "user",
            content: [
              OpenRouter.cached_content(context_block),
              %{type: "text", text: "[Context injected by system. Proceed with the conversation below.]"}
            ]
          },
          %{
            role: "assistant",
            content: "Understood. I have the context. How can I help?"
          }
        ]
      else
        []
      end

    # Compute available token budget from model context window and limits config
    token_budget = compute_history_token_budget(role)
    last_prompt_tokens = loop_state[:last_prompt_tokens]
    last_message_count = loop_state[:last_message_count] || 0

    trimmed = trim_messages(messages, token_budget, last_prompt_tokens, last_message_count)

    context_messages ++ trimmed
  end

  defp compute_history_token_budget(role) do
    limits = ConfigLoader.limits_config()

    max_context =
      case ConfigLoader.model_for(role) do
        %{max_context_tokens: tokens} -> tokens
        nil -> 200_000
      end

    # Available = (max_context * utilization_target) - response_reserve
    available = trunc(max_context * limits.context_utilization_target) - limits.response_reserve_tokens
    max(available, 1_000)
  end

  defp trim_messages(messages, token_budget, last_prompt_tokens, last_message_count) do
    # Two strategies based on whether we have actual token usage from the API:
    #
    # 1. Usage-based (preferred): last_prompt_tokens from OpenRouter tells us
    #    exactly how many tokens the prior request consumed (system + tools +
    #    context block + all messages). We use that as baseline and only estimate
    #    deltas for messages added since.
    #
    # 2. Pure estimation (fallback): First message in conversation has no prior
    #    usage data. Estimate all messages at ~4 chars/token.
    case last_prompt_tokens do
      nil ->
        # Fallback: no prior usage data, estimate everything
        trim_messages_by_estimation(messages, token_budget)

      baseline when is_integer(baseline) and baseline > 0 ->
        # Usage-based: baseline covers messages[0..last_message_count-1].
        # Estimate only new messages added since the last LLM call.
        trim_messages_by_usage(messages, token_budget, baseline, last_message_count)

      _ ->
        # Safety fallback for unexpected values (0, negative, non-integer)
        trim_messages_by_estimation(messages, token_budget)
    end
  end

  # Pure estimation fallback: walk newest-first, accumulate estimated tokens.
  defp trim_messages_by_estimation(messages, token_budget) do
    messages
    |> Enum.reverse()
    |> Enum.reduce_while({[], 0}, fn msg, {kept, total_tokens} ->
      msg_tokens = estimate_message_tokens(msg)
      new_total = total_tokens + msg_tokens

      if new_total <= token_budget do
        {:cont, {[msg | kept], new_total}}
      else
        {:halt, {kept, total_tokens}}
      end
    end)
    |> elem(0)
  end

  # Usage-based trimming: use actual API prompt_tokens as baseline for known
  # messages, then estimate deltas for new messages only.
  defp trim_messages_by_usage(messages, token_budget, baseline, last_message_count) do
    msg_count = length(messages)

    # Split into known (covered by baseline) and new (needing estimation)
    {known_msgs, new_msgs} =
      if last_message_count >= msg_count do
        # All messages were in the prior request (shouldn't happen, but safe)
        {messages, []}
      else
        Enum.split(messages, last_message_count)
      end

    # Estimate tokens for new messages only
    new_tokens = Enum.reduce(new_msgs, 0, &(estimate_message_tokens(&1) + &2))
    total_estimated = baseline + new_tokens

    if total_estimated <= token_budget do
      # Everything fits — no trimming needed
      messages
    else
      # Need to trim. Remove oldest known messages first (preserve new messages
      # since they contain the most recent context — tool results, dispatches).
      overshoot = total_estimated - token_budget
      {_trimmed, kept_known} = trim_oldest(known_msgs, overshoot)
      kept_known ++ new_msgs
    end
  end

  # Remove oldest messages until we've freed at least `tokens_to_free` tokens.
  # Returns {freed_tokens, remaining_messages}.
  defp trim_oldest(messages, tokens_to_free) do
    do_trim_oldest(messages, tokens_to_free, 0)
  end

  defp do_trim_oldest([], _tokens_to_free, freed), do: {freed, []}

  defp do_trim_oldest(remaining, tokens_to_free, freed) when freed >= tokens_to_free do
    {freed, remaining}
  end

  defp do_trim_oldest([msg | rest], tokens_to_free, freed) do
    msg_tokens = estimate_message_tokens(msg)
    do_trim_oldest(rest, tokens_to_free, freed + msg_tokens)
  end

  defp estimate_message_tokens(message) do
    text =
      case message do
        %{content: content} when is_binary(content) -> content
        %{content: parts} when is_list(parts) -> extract_text_from_parts(parts)
        %{"content" => content} when is_binary(content) -> content
        %{"content" => parts} when is_list(parts) -> extract_text_from_parts(parts)
        _ -> ""
      end

    # ~4 chars per token + small overhead for message framing
    div(String.length(text), @chars_per_token) + 4
  end

  defp extract_text_from_parts(parts) do
    Enum.map_join(parts, " ", fn
      %{text: text} when is_binary(text) -> text
      %{"text" => text} when is_binary(text) -> text
      _ -> ""
    end)
  end

  # --- Private: Tool Wrapping ---

  defp wrap_function_tool(tool_def) do
    %{
      type: "function",
      function: tool_def
    }
  end
end
