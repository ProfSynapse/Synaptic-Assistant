# lib/assistant/orchestrator/context.ex — Context assembly for orchestrator LLM calls.
#
# Builds cache-friendly message payloads for the orchestrator. The message
# structure is ordered for prompt caching: static prefix first (system prompt
# + tool defs) → cache breakpoint → dynamic messages (memory, history, user
# message). The orchestrator tools (get_skill, dispatch_agent, get_agent_results)
# are compiled once as module attributes and never change at runtime.
#
# Related files:
#   - lib/assistant/integrations/openrouter.ex (cached_content helper)
#   - lib/assistant/orchestrator/tools/get_skill.ex (tool definition)
#   - lib/assistant/orchestrator/tools/dispatch_agent.ex (tool definition)
#   - lib/assistant/orchestrator/tools/get_agent_results.ex (tool definition)
#   - lib/assistant/skills/registry.ex (domain listing)
#   - lib/assistant/config/loader.ex (model roster, limits config)

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
  alias Assistant.Integrations.OpenRouter
  alias Assistant.Orchestrator.Tools.{DispatchAgent, GetAgentResults, GetSkill}
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
      wrap_function_tool(GetSkill.tool_definition())
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
    context_and_messages = build_message_sequence(context_block, messages, role)

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

    """
    You are an AI assistant orchestrator. You coordinate sub-agents to fulfill user requests.

    Your workflow:
    1. Understand the user's request
    2. Call get_skill to discover relevant capabilities
    3. Decompose the request into sub-tasks
    4. Dispatch sub-agents via dispatch_agent (one per sub-task)
    5. Collect results via get_agent_results
    6. Synthesize a clear response for the user once done

    Rules:
    - You NEVER execute skills directly — always delegate to sub-agents
    - For simple single-skill requests, dispatch one agent (don't over-decompose)
    - For multi-step requests, identify dependencies and parallelize where possible
    - Agent missions should be specific and self-contained
    - Only give agents the skills they need (principle of least privilege)
    - If an agent fails, decide: retry with adjusted mission, skip, or report to user

    Available skill domains: #{Enum.join(domains, ", ")}

    User: #{loop_state[:user_id] || "unknown"}
    Channel: #{loop_state[:channel] || "unknown"}
    Date: #{Date.utc_today() |> Date.to_iso8601()}
    """
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

  defp build_message_sequence(context_block, messages, role) do
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
    trimmed = trim_messages(messages, token_budget)

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

  defp trim_messages(messages, token_budget) do
    # Trim oldest messages first until total estimated tokens fit within budget.
    # Approximation: ~4 characters per token (good enough for trimming heuristic).
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
