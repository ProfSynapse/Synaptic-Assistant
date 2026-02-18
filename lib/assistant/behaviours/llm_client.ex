# lib/assistant/behaviours/llm_client.ex — LLMClient behaviour definition.
#
# Defines the contract for LLM providers used by the orchestration engine.
# The primary implementation is Assistant.Integrations.OpenRouter.
# In tests, use Mox to define MockLLMClient against this behaviour.

defmodule Assistant.Behaviours.LLMClient do
  @moduledoc """
  Behaviour for LLM chat completion providers.

  Defines the contract that any LLM client must implement, enabling
  provider-agnostic orchestration and Mox-based testing.

  ## Implementations

    - `Assistant.Integrations.OpenRouter` — Production client (OpenRouter API)
    - `MockLLMClient` — Test mock (defined via Mox in test/support/mocks.ex)

  ## Configuration

  The active implementation is selected via application config:

      config :assistant, :llm_client, Assistant.Integrations.OpenRouter

  Consumers should use `Application.compile_env/3` for compile-time resolution:

      @llm_client Application.compile_env(:assistant, :llm_client, Assistant.Integrations.OpenRouter)
  """

  @typedoc "A single message in the conversation (role + content/tool_calls)."
  @type message :: %{
          required(:role) => String.t(),
          optional(:content) => String.t() | [content_part()],
          optional(:tool_calls) => [tool_call()],
          optional(:tool_call_id) => String.t()
        }

  @typedoc "A content part for multimodal messages (text, audio, cache_control)."
  @type content_part :: %{
          required(:type) => String.t(),
          optional(:text) => String.t(),
          optional(:cache_control) => cache_control(),
          optional(:input_audio) => %{data: String.t(), format: String.t()}
        }

  @typedoc "Cache control directive for prompt caching."
  @type cache_control :: %{
          required(:type) => String.t(),
          optional(:ttl) => String.t()
        }

  @typedoc "An OpenAI-format tool definition."
  @type tool_definition :: %{
          required(:type) => String.t(),
          required(:function) => %{
            required(:name) => String.t(),
            required(:description) => String.t(),
            required(:parameters) => map()
          }
        }

  @typedoc "A tool call from the assistant response."
  @type tool_call :: %{
          required(:id) => String.t(),
          required(:type) => String.t(),
          required(:function) => %{
            required(:name) => String.t(),
            required(:arguments) => String.t()
          }
        }

  @typedoc "Token usage details returned with completions."
  @type usage :: %{
          required(:prompt_tokens) => non_neg_integer(),
          required(:completion_tokens) => non_neg_integer(),
          required(:total_tokens) => non_neg_integer(),
          optional(:cached_tokens) => non_neg_integer(),
          optional(:cache_write_tokens) => non_neg_integer(),
          optional(:audio_tokens) => non_neg_integer(),
          optional(:reasoning_tokens) => non_neg_integer(),
          optional(:cost) => float() | nil
        }

  @typedoc "Parsed completion response."
  @type completion_response :: %{
          required(:id) => String.t(),
          required(:model) => String.t(),
          required(:content) => String.t() | nil,
          required(:tool_calls) => [tool_call()],
          required(:finish_reason) => String.t(),
          required(:usage) => usage()
        }

  @typedoc "A chunk from a streaming response."
  @type stream_chunk :: %{
          optional(:content) => String.t(),
          optional(:tool_calls) => [map()],
          optional(:finish_reason) => String.t() | nil,
          optional(:usage) => usage()
        }

  @typedoc "Callback function invoked for each streaming chunk."
  @type stream_callback :: (stream_chunk() -> :ok | {:error, term()})

  @doc """
  Send a chat completion request (non-streaming).

  ## Parameters

    - `messages` — Conversation message list (system, user, assistant, tool roles)
    - `opts` — Keyword options:
      - `:model` — Model ID (default from config)
      - `:tools` — List of tool definitions
      - `:tool_choice` — Tool selection strategy ("auto", "none", "required")
      - `:temperature` — Sampling temperature (0.0-2.0)
      - `:max_tokens` — Maximum completion tokens

  ## Returns

    - `{:ok, completion_response()}` on success
    - `{:error, term()}` on failure
  """
  @callback chat_completion(messages :: [message()], opts :: keyword()) ::
              {:ok, completion_response()} | {:error, term()}

  @doc """
  Send a streaming chat completion request.

  The callback is invoked for each SSE chunk. The final chunk includes
  usage data and a non-nil finish_reason.

  ## Parameters

    - `messages` — Conversation message list
    - `callback` — Function called with each parsed chunk
    - `opts` — Same options as `chat_completion/2`

  ## Returns

    - `{:ok, final_usage}` when stream completes successfully
    - `{:error, term()}` on failure
  """
  @callback streaming_completion(
              messages :: [message()],
              callback :: stream_callback(),
              opts :: keyword()
            ) ::
              {:ok, usage()} | {:error, term()}
end
