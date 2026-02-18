# lib/assistant/integrations/openrouter.ex — OpenRouter LLM client.
#
# HTTP client for the OpenRouter chat completions API. Handles tool-calling,
# prompt caching (cache_control breakpoints), streaming (SSE), and audio
# input (STT via chat completions). Used by the orchestration engine for
# all LLM interactions.
#
# Related files:
#   - lib/assistant/behaviours/llm_client.ex (behaviour contract)
#   - lib/assistant/config/loader.ex (model roster, HTTP config from models.yaml)
#   - config/runtime.exs (API key configuration)

defmodule Assistant.Integrations.OpenRouter do
  @moduledoc """
  OpenRouter API client for LLM chat completions with tool calling and prompt caching.

  Implements the `Assistant.Behaviours.LLMClient` behaviour. Communicates with
  the OpenRouter API (`https://openrouter.ai/api/v1`) using Req for HTTP.

  ## Features

    - Non-streaming chat completions (default mode)
    - Streaming completions via SSE with callback
    - Tool-calling with OpenAI-format tool definitions
    - Prompt caching with `cache_control` breakpoints (Anthropic: max 4 breakpoints)
    - Audio input via chat completions (STT for voice channel)
    - Alphabetical tool sorting for consistent cache keys

  ## Prompt Caching Strategy

  Cache breakpoints are placed on stable content blocks to maximize cache hits:

    1. System prompt — 1-hour TTL (`cache_control: %{type: "ephemeral", ttl: "1h"}`)
    2. Context block — 5-min TTL (default `cache_control: %{type: "ephemeral"}`)
    3-4. Reserved for future use (large document injection, skill results)

  Tool definitions are sorted alphabetically by function name before each request
  to ensure consistent serialization across agent instances and conversations.

  ## Configuration

      # config/runtime.exs
      config :assistant, :openrouter_api_key, System.fetch_env!("OPENROUTER_API_KEY")

  ## Model Selection

  This client does **not** have a default model. Callers must always pass
  `:model` in the opts keyword list. Model selection is the responsibility of
  `Assistant.Config.Loader`, which resolves model IDs from `config/models.yaml`
  based on role (orchestrator, sub_agent, compaction, etc.).

  ## HTTP Settings

  Retry, backoff, and timeout parameters are loaded at call time from
  `Assistant.Config.Loader.http_config/0` (sourced from the `http:` section
  of `config/models.yaml`). No defaults are hardcoded in this module.
  """

  @behaviour Assistant.Behaviours.LLMClient

  require Logger

  alias Assistant.Config.Loader, as: ConfigLoader

  @base_url "https://openrouter.ai/api/v1"

  # --- Public API ---

  @doc """
  Send a non-streaming chat completion request.

  This is the default execution mode for orchestrator and sub-agent loops.
  Tool definitions are sorted alphabetically for cache consistency.

  ## Options (required)

    - `:model` — Model ID from `config/models.yaml` (e.g. `"anthropic/claude-sonnet-4-6"`).
      **Required.** Resolve via `Assistant.Config.Loader.model_for/1`.

  ## Options (optional)

    - `:tools` — List of tool definitions (will be sorted alphabetically)
    - `:tool_choice` — `"auto"`, `"none"`, `"required"` (default: `"auto"` when tools present)
    - `:temperature` — Sampling temperature (default: provider default)
    - `:max_tokens` — Maximum completion tokens
    - `:parallel_tool_calls` — Allow parallel tool calls (default: provider default)

  ## Examples

      messages = [
        %{role: "system", content: "You are a helpful assistant."},
        %{role: "user", content: "Hello"}
      ]

      {:ok, response} = OpenRouter.chat_completion(messages, model: "anthropic/claude-sonnet-4-6")
      response.content  # => "Hello! How can I help?"

  Returns `{:error, :no_model_specified}` if `:model` is not provided.
  """
  @impl true
  def chat_completion(messages, opts \\ []) do
    with {:ok, body} <- build_request_body(messages, opts) do
      case do_request(body) do
        {:ok, %{status: 200, body: response_body}} ->
          parse_completion(response_body)

        {:ok, %{status: 429} = response} ->
          retry_after = extract_retry_after(response)
          {:error, {:rate_limited, retry_after}}

        {:ok, %{status: 402, body: resp_body}} ->
          {:error, {:insufficient_credits, get_in(resp_body, ["error", "message"])}}

        {:ok, %{status: status, body: resp_body}} when status >= 400 ->
          error_message = get_in(resp_body, ["error", "message"]) || "Unknown error"
          Logger.error("OpenRouter API error",
            status: status,
            error: error_message
          )
          {:error, {:api_error, status, error_message}}

        {:error, %Req.TransportError{reason: reason}} ->
          Logger.error("OpenRouter connection error", reason: inspect(reason))
          {:error, {:connection_error, reason}}

        {:error, reason} ->
          Logger.error("OpenRouter request failed", reason: inspect(reason))
          {:error, {:request_failed, reason}}
      end
    end
  end

  @doc """
  Send a streaming chat completion request via SSE.

  The callback receives parsed chunks as they arrive. OpenRouter SSE comment
  frames (`: OPENROUTER PROCESSING`) are silently ignored. The final chunk
  includes usage data.

  ## Options

  Same as `chat_completion/2`.

  ## Callback

  The callback receives `%{content: ..., tool_calls: ..., finish_reason: ..., usage: ...}`
  maps. Not all fields are present on every chunk.

  ## Examples

      callback = fn chunk ->
        if content = chunk[:content], do: IO.write(content)
        :ok
      end

      {:ok, usage} = OpenRouter.streaming_completion(messages, callback, tools: tool_defs)
  """
  @impl true
  def streaming_completion(messages, callback, opts \\ []) do
    with {:ok, base_body} <- build_request_body(messages, opts) do
      body =
        base_body
        |> Map.put(:stream, true)
        |> Map.put(:stream_options, %{include_usage: true})

      # Use process dictionary to accumulate usage from the final SSE chunk.
      # The stream handler callback runs in the same process as Req.post/2,
      # so process dictionary is safe here without concurrency concerns.
      Process.put(:openrouter_stream_usage, nil)

      stream_handler = fn {:data, data}, {req, resp} ->
        data
        |> String.split("\n")
        |> Enum.each(fn line ->
          handle_sse_line(line, callback)
        end)

        {:cont, {req, resp}}
      end

      http = ConfigLoader.http_config()
      req = build_req_client(http, :streaming)

      case Req.post(req, url: "/chat/completions", json: body, into: stream_handler) do
        {:ok, %{status: 200}} ->
          final_usage = Process.delete(:openrouter_stream_usage) || empty_usage()
          {:ok, final_usage}

        {:ok, %{status: 429} = response} ->
          Process.delete(:openrouter_stream_usage)
          retry_after = extract_retry_after(response)
          {:error, {:rate_limited, retry_after}}

        {:ok, %{status: status, body: resp_body}} when status >= 400 ->
          Process.delete(:openrouter_stream_usage)
          error_message = get_in(resp_body, ["error", "message"]) || "Unknown error"
          {:error, {:api_error, status, error_message}}

        {:error, reason} ->
          Process.delete(:openrouter_stream_usage)
          Logger.error("OpenRouter streaming request failed", reason: inspect(reason))
          {:error, {:request_failed, reason}}
      end
    end
  end

  # --- Request Building ---

  @doc false
  def build_request_body(messages, opts) do
    case Keyword.fetch(opts, :model) do
      {:ok, model} ->
        body =
          %{model: model, messages: messages}
          |> maybe_add_tools(opts)
          |> maybe_add_tool_choice(opts)
          |> maybe_add_temperature(opts)
          |> maybe_add_max_tokens(opts)
          |> maybe_add_parallel_tool_calls(opts)

        {:ok, body}

      :error ->
        {:error, :no_model_specified}
    end
  end

  defp maybe_add_tools(body, opts) do
    case Keyword.get(opts, :tools) do
      nil -> body
      [] -> body
      tools -> Map.put(body, :tools, sort_tools(tools))
    end
  end

  defp maybe_add_tool_choice(body, opts) do
    case Keyword.get(opts, :tool_choice) do
      nil ->
        if Map.has_key?(body, :tools) do
          Map.put(body, :tool_choice, "auto")
        else
          body
        end

      choice ->
        Map.put(body, :tool_choice, choice)
    end
  end

  defp maybe_add_temperature(body, opts) do
    case Keyword.get(opts, :temperature) do
      nil -> body
      temp -> Map.put(body, :temperature, temp)
    end
  end

  defp maybe_add_max_tokens(body, opts) do
    case Keyword.get(opts, :max_tokens) do
      nil -> body
      max -> Map.put(body, :max_tokens, max)
    end
  end

  defp maybe_add_parallel_tool_calls(body, opts) do
    case Keyword.get(opts, :parallel_tool_calls) do
      nil -> body
      value -> Map.put(body, :parallel_tool_calls, value)
    end
  end

  @doc """
  Sort tool definitions alphabetically by function name.

  Ensures consistent serialization across requests for maximum prompt cache
  hit rates. The OpenRouter/Anthropic cache key depends on exact request
  prefix — reordering tools invalidates the cache.

  ## Examples

      tools = [
        %{type: "function", function: %{name: "use_skill", ...}},
        %{type: "function", function: %{name: "get_skill", ...}}
      ]

      sorted = OpenRouter.sort_tools(tools)
      # => [%{... name: "get_skill" ...}, %{... name: "use_skill" ...}]
  """
  def sort_tools(tools) do
    Enum.sort_by(tools, fn
      %{function: %{name: name}} -> name
      %{"function" => %{"name" => name}} -> name
      _ -> ""
    end)
  end

  # --- Response Parsing ---

  defp parse_completion(body) do
    with %{"choices" => [choice | _]} <- body,
         %{"message" => message, "finish_reason" => finish_reason} <- choice do
      tool_calls = parse_tool_calls(message)
      usage = parse_usage(body)

      {:ok,
       %{
         id: body["id"],
         model: body["model"],
         content: message["content"],
         tool_calls: tool_calls,
         finish_reason: finish_reason,
         usage: usage
       }}
    else
      _ ->
        Logger.error("OpenRouter unexpected response format", body: inspect(body))
        {:error, {:unexpected_response, body}}
    end
  end

  defp parse_tool_calls(%{"tool_calls" => tool_calls}) when is_list(tool_calls) do
    Enum.map(tool_calls, fn tc ->
      %{
        id: tc["id"],
        type: tc["type"] || "function",
        function: %{
          name: get_in(tc, ["function", "name"]),
          arguments: get_in(tc, ["function", "arguments"])
        }
      }
    end)
  end

  defp parse_tool_calls(_), do: []

  defp parse_usage(%{"usage" => usage}) when is_map(usage) do
    details = usage["prompt_tokens_details"] || %{}

    %{
      prompt_tokens: usage["prompt_tokens"] || 0,
      completion_tokens: usage["completion_tokens"] || 0,
      total_tokens: usage["total_tokens"] || 0,
      cached_tokens: details["cached_tokens"] || 0,
      cache_write_tokens: details["cache_write_tokens"] || 0
    }
  end

  defp parse_usage(_) do
    %{
      prompt_tokens: 0,
      completion_tokens: 0,
      total_tokens: 0,
      cached_tokens: 0,
      cache_write_tokens: 0
    }
  end

  # --- SSE Stream Handling ---

  defp handle_sse_line("data: [DONE]", _callback), do: :ok

  defp handle_sse_line("data: " <> json, callback) do
    case Jason.decode(json) do
      {:ok, chunk} ->
        parsed = parse_stream_chunk(chunk)

        # Capture usage from final chunk (has finish_reason and usage data)
        if parsed[:usage], do: Process.put(:openrouter_stream_usage, parsed[:usage])

        callback.(parsed)

      {:error, _} ->
        :ok
    end
  end

  # Ignore SSE comment frames (": OPENROUTER PROCESSING" etc.) and blank lines
  defp handle_sse_line(_, _callback), do: :ok

  defp parse_stream_chunk(chunk) do
    delta =
      chunk
      |> get_in(["choices", Access.at(0), "delta"])
      |> case do
        nil -> %{}
        d -> d
      end

    finish_reason =
      get_in(chunk, ["choices", Access.at(0), "finish_reason"])

    result = %{}

    result =
      case delta["content"] do
        nil -> result
        content -> Map.put(result, :content, content)
      end

    result =
      case delta["tool_calls"] do
        nil -> result
        tcs -> Map.put(result, :tool_calls, tcs)
      end

    result =
      if finish_reason do
        Map.put(result, :finish_reason, finish_reason)
      else
        result
      end

    case chunk["usage"] do
      nil -> result
      usage -> Map.put(result, :usage, parse_usage(%{"usage" => usage}))
    end
  end

  # --- HTTP Client ---

  defp do_request(body) do
    http = ConfigLoader.http_config()
    req = build_req_client(http, :request)
    Req.post(req, url: "/chat/completions", json: body)
  end

  defp build_req_client(http, mode) do
    timeout =
      case mode do
        :streaming -> http.streaming_timeout_ms
        :request -> http.request_timeout_ms
      end

    Req.new(
      base_url: base_url(),
      headers: [
        {"authorization", "Bearer #{api_key()}"},
        {"content-type", "application/json"}
      ],
      retry: :safe_transient,
      max_retries: http.max_retries,
      retry_delay: fn retry_count ->
        exponential_backoff(retry_count, http.base_backoff_ms, http.max_backoff_ms)
      end,
      receive_timeout: timeout
    )
  end

  defp exponential_backoff(retry_count, base_backoff_ms, max_backoff_ms) do
    base_delay = Integer.pow(2, retry_count) * base_backoff_ms
    jitter = :rand.uniform(div(base_backoff_ms, 2))
    min(base_delay + jitter, max_backoff_ms)
  end

  defp extract_retry_after(%{headers: headers}) when is_map(headers) do
    # Req stores headers as %{"name" => ["value1", ...]} (lowercase keys)
    case headers["retry-after"] do
      [value | _] ->
        case Integer.parse(value) do
          {seconds, _} -> seconds
          :error -> 60
        end

      _ ->
        60
    end
  end

  defp extract_retry_after(_), do: 60

  defp empty_usage do
    %{
      prompt_tokens: 0,
      completion_tokens: 0,
      total_tokens: 0,
      cached_tokens: 0,
      cache_write_tokens: 0
    }
  end

  # --- Configuration ---

  defp api_key do
    Application.fetch_env!(:assistant, :openrouter_api_key)
  end

  defp base_url do
    Application.get_env(:assistant, :openrouter_base_url, @base_url)
  end

  # --- Prompt Caching Helpers ---

  @doc """
  Wrap text content with a cache control breakpoint.

  Used when building messages with prompt caching. Place on stable content
  blocks (system prompt, context) to enable Anthropic prompt caching.

  ## Options

    - `:ttl` — Cache TTL. `"1h"` for 1-hour (orchestrator), omit for default 5min (sub-agents).

  ## Examples

      # Orchestrator system prompt (1-hour TTL, 4 breakpoints max)
      %{
        role: "system",
        content: [
          OpenRouter.cached_content("System prompt text...", ttl: "1h")
        ]
      }

      # Sub-agent context (default 5-min TTL)
      %{
        role: "user",
        content: [
          OpenRouter.cached_content("Context block..."),
          %{type: "text", text: "Current user message"}
        ]
      }
  """
  def cached_content(text, opts \\ []) do
    cache_control =
      case Keyword.get(opts, :ttl) do
        nil -> %{type: "ephemeral"}
        ttl -> %{type: "ephemeral", ttl: ttl}
      end

    %{
      type: "text",
      text: text,
      cache_control: cache_control
    }
  end

  @doc """
  Build an audio input content part for STT via chat completions.

  OpenRouter handles audio transcription through the chat completions endpoint.
  Audio must be base64-encoded. The model processes audio + text context together.

  ## Parameters

    - `base64_audio` — Base64-encoded audio data
    - `format` — Audio format: "wav", "mp3", "ogg", "flac", etc.

  ## Examples

      audio_part = OpenRouter.audio_content(base64_data, "wav")
      text_part = %{type: "text", text: "Transcribe and respond to this audio."}

      messages = [
        %{role: "user", content: [text_part, audio_part]}
      ]

      {:ok, response} = OpenRouter.chat_completion(messages, model: "google/gemini-2.5-flash")
  """
  def audio_content(base64_audio, format) when is_binary(base64_audio) and is_binary(format) do
    %{
      type: "input_audio",
      input_audio: %{
        data: base64_audio,
        format: format
      }
    }
  end
end
