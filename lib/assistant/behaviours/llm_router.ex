# lib/assistant/behaviours/llm_router.ex — LLMRouter behaviour definition.
#
# Defines the contract for user-aware LLM routing used by modules that
# need to respect per-user provider credentials (e.g., ChatGPT via OAuth).
# The primary implementation is Assistant.Integrations.LLMRouter.
# In tests, use Mox to define MockLLMRouter against this behaviour.

defmodule Assistant.Behaviours.LLMRouter do
  @moduledoc """
  Behaviour for user-aware LLM routing.

  Unlike `LLMClient` (which targets a single provider), this behaviour
  routes calls to the correct provider based on the user's connected
  credentials (OpenRouter, OpenAI/ChatGPT, etc.).

  ## Implementations

    - `Assistant.Integrations.LLMRouter` — Production router
    - `MockLLMRouter` — Test mock (defined via Mox in test/support/mocks.ex)

  ## Configuration

  The active implementation is selected via application config:

      config :assistant, :llm_router, Assistant.Integrations.LLMRouter
  """

  @doc """
  Send a chat completion request routed by user credentials.

  ## Parameters

    - `messages` — Conversation message list
    - `opts` — Keyword options (model, temperature, max_tokens, etc.)
    - `user_id` — The user ID for credential resolution (may be nil)

  ## Returns

    - `{:ok, completion_response()}` on success
    - `{:error, term()}` on failure
  """
  @callback chat_completion(messages :: [map()], opts :: keyword(), user_id :: String.t() | nil) ::
              {:ok, map()} | {:error, term()}
end
