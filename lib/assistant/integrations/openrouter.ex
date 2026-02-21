# lib/assistant/integrations/openrouter.ex — OpenRouter LLM client.
#
# HTTP client for the OpenRouter chat completions API. Handles tool-calling,
# prompt caching (cache_control breakpoints), streaming (SSE), and audio
# input (STT via chat completions). Used by the orchestration engine for
# all LLM interactions. Supports per-user API key override (via :api_key opt)
# with fallback to the system-level key.
#
# Related files:
#   - lib/assistant/behaviours/llm_client.ex (behaviour contract)
#   - lib/assistant/config/loader.ex (model roster, HTTP config from config.yaml)
#   - config/runtime.exs (API key configuration)

defmodule Assistant.Integrations.OpenRouter do
  @moduledoc """
  OpenRouter API client for LLM chat completions with tool calling and prompt caching.

  Implements the `Assistant.Behaviours.LLMClient` behaviour. Communicates with
  the OpenRouter API (`https://openrouter.ai/api/v1`) using Req for HTTP.

  ## Features

    - Non-streaming chat completions (default mode)
    - Streaming completions via SSE with callback
    - Image generation via chat completions (`modalities: ["image", "text"]`)
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

  ## API Key Resolution

  When a per-user API key is provided via the `:api_key` option, it takes
  precedence over the system-level key. This allows users who have connected
  their own OpenRouter account (via PKCE OAuth) to use their personal key
  and billing. If no per-user key is provided, the system key is used.

  ## Configuration

      # config/runtime.exs
      config :assistant, :openrouter_api_key, System.fetch_env!("OPENROUTER_API_KEY")

  ## Model Selection

  This client does **not** have a default model. Callers must always pass
  `:model` in the opts keyword list. Model selection is the responsibility of
  `Assistant.Config.Loader`, which resolves model IDs from `config/config.yaml`
  based on role (orchestrator, sub_agent, compaction, etc.).

  ## HTTP Settings

  Retry, backoff, and timeout parameters are loaded at call time from
  `Assistant.Config.Loader.http_config/0` (sourced from the `http:` section
  of `config/config.yaml`). No defaults are hardcoded in this module.
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

    - `:model` — Model ID from `config/config.yaml` (e.g. `"anthropic/claude-sonnet-4-6"`).
      **Required.** Resolve via `Assistant.Config.Loader.model_for/1`.

  ## Options (optional)

    - `:tools` — List of tool definitions (will be sorted alphabetically)
    - `:tool_choice` — `"auto"`, `"none"`, `"required"` (default: `"auto"` when tools present)
    - `:temperature` — Sampling temperature (default: provider default)
    - `:max_tokens` — Maximum completion tokens
    - `:parallel_tool_calls` — Allow parallel tool calls (default: provider default)
    - `:response_format` — Response format constraint (`%{type: "json_object"}` or
      `%{type: "json_schema", json_schema: %{...}}` for structured outputs)
    - `:api_key` — Per-user OpenRouter API key. When provided, overrides the
      system-level key for this request. Falls back to the system key if nil.

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
      case do_request(body, Keyword.get(opts, :api_key)) do
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
      req = build_req_client(http, :streaming, Keyword.get(opts, :api_key))

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

  @doc """
  Validates an OpenRouter API key by calling the key metadata endpoint.
  """
  @spec validate_api_key(String.t()) :: :ok | {:error, term()}
  def validate_api_key(api_key) when is_binary(api_key) and api_key != "" do
    http = ConfigLoader.http_config()
    req = build_req_client(http, :request, api_key)

    case Req.get(req, url: "/key") do
      {:ok, %{status: 200}} ->
        :ok

      {:ok, %{status: status, body: body}} when status >= 400 ->
        {:error, {:api_error, status, get_in(body, ["error", "message"])}}

      {:error, reason} ->
        {:error, {:request_failed, reason}}
    end
  end

  def validate_api_key(_), do: {:error, :invalid_api_key}

  @doc """
  Lists OpenRouter model IDs visible to the provided API key.
  """
  @spec list_models(String.t()) :: {:ok, [String.t()]} | {:error, term()}
  def list_models(api_key) when is_binary(api_key) and api_key != "" do
    http = ConfigLoader.http_config()
    req = build_req_client(http, :request, api_key)

    case Req.get(req, url: "/models/user") do
      {:ok, %{status: 200, body: %{"data" => data}}} when is_list(data) ->
        model_ids =
          data
          |> Enum.map(&Map.get(&1, "id"))
          |> Enum.filter(&is_binary/1)

        {:ok, model_ids}

      {:ok, %{status: status, body: body}} when status >= 400 ->
        {:error, {:api_error, status, get_in(body, ["error", "message"])}}

      {:error, reason} ->
        {:error, {:request_failed, reason}}

      _ ->
        {:error, :unexpected_response}
    end
  end

  def list_models(_), do: {:error, :invalid_api_key}

  @doc """
  Lists detailed OpenRouter model metadata for model catalog browsing.

  Returns normalized maps with:
    - `:id`
    - `:name`
    - `:input_cost`
    - `:output_cost`
    - `:max_context_tokens`
  """
  @spec list_models_detailed(String.t()) :: {:ok, [map()]} | {:error, term()}
  def list_models_detailed(api_key) when is_binary(api_key) and api_key != "" do
    http = ConfigLoader.http_config()
    req = build_req_client(http, :request, api_key)

    case Req.get(req, url: "/models/user") do
      {:ok, %{status: 200, body: %{"data" => data}}} when is_list(data) ->
        models =
          data
          |> Enum.map(&normalize_model_details/1)
          |> Enum.reject(&is_nil/1)
          |> Enum.uniq_by(& &1.id)
          |> Enum.sort_by(&String.downcase(&1.name || &1.id))

        {:ok, models}

      {:ok, %{status: status, body: body}} when status >= 400 ->
        {:error, {:api_error, status, get_in(body, ["error", "message"])}}

      {:error, reason} ->
        {:error, {:request_failed, reason}}

      _ ->
        {:error, :unexpected_response}
    end
  end

  def list_models_detailed(_), do: {:error, :invalid_api_key}

  @doc """
  Generate images using OpenRouter's chat completions image modality.

  Sends a user prompt with `modalities: ["image", "text"]` and optional
  image options (`n`, `size`, `aspect_ratio`) via the `/chat/completions`
  endpoint.

  ## Options (required)

    - `:model` — Image-capable model ID (for example, `"openai/gpt-5-image-mini"`).

  ## Options (optional)

    - `:n` — Number of images requested
    - `:size` — Image size string (for example, `"1024x1024"`)
    - `:aspect_ratio` — Aspect ratio string (for example, `"16:9"`)

  Returns `{:error, :no_model_specified}` if `:model` is missing.
  """
  @spec image_generation(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def image_generation(prompt, opts \\ []) when is_binary(prompt) do
    with {:ok, body} <- build_image_request_body(prompt, opts) do
      case do_request(body, Keyword.get(opts, :api_key)) do
        {:ok, %{status: 200, body: response_body}} ->
          parse_image_completion(response_body)

        {:ok, %{status: 429} = response} ->
          retry_after = extract_retry_after(response)
          {:error, {:rate_limited, retry_after}}

        {:ok, %{status: 402, body: resp_body}} ->
          {:error, {:insufficient_credits, get_in(resp_body, ["error", "message"])}}

        {:ok, %{status: status, body: resp_body}} when status >= 400 ->
          error_message = get_in(resp_body, ["error", "message"]) || "Unknown error"
          Logger.error("OpenRouter image API error", status: status, error: error_message)
          {:error, {:api_error, status, error_message}}

        {:error, %Req.TransportError{reason: reason}} ->
          Logger.error("OpenRouter image connection error", reason: inspect(reason))
          {:error, {:connection_error, reason}}

        {:error, reason} ->
          Logger.error("OpenRouter image request failed", reason: inspect(reason))
          {:error, {:request_failed, reason}}
      end
    end
  end

  # --- Image Request Building ---

  @doc false
  def build_image_request_body(prompt, opts) do
    case Keyword.fetch(opts, :model) do
      {:ok, model} ->
        base_body = %{
          model: model,
          messages: [%{role: "user", content: prompt}],
          modalities: ["image", "text"]
        }

        image_opts =
          %{}
          |> maybe_put_image_opt(:n, Keyword.get(opts, :n), &valid_positive_integer?/1)
          |> maybe_put_image_opt(:size, Keyword.get(opts, :size), &valid_non_empty_string?/1)
          |> maybe_put_image_opt(
            :aspect_ratio,
            Keyword.get(opts, :aspect_ratio),
            &valid_non_empty_string?/1
          )

        body =
          if map_size(image_opts) > 0 do
            Map.put(base_body, :image, image_opts)
          else
            base_body
          end

        {:ok, body}

      :error ->
        {:error, :no_model_specified}
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
          |> maybe_add_response_format(opts)

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

  defp maybe_add_response_format(body, opts) do
    case Keyword.get(opts, :response_format) do
      nil -> body
      format -> Map.put(body, :response_format, format)
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
         content: extract_text_content(message["content"]),
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

  defp parse_image_completion(body) do
    with %{"choices" => [choice | _]} <- body,
         %{"message" => message, "finish_reason" => finish_reason} <- choice do
      usage = parse_usage(body)

      {:ok,
       %{
         id: body["id"],
         model: body["model"],
         content: extract_text_content(message["content"]),
         images: parse_images(message),
         finish_reason: finish_reason,
         usage: usage
       }}
    else
      _ ->
        Logger.error("OpenRouter unexpected image response format", body: inspect(body))
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

  defp parse_images(%{"images" => images}) when is_list(images) do
    images
    |> Enum.map(fn image ->
      url = get_in(image, ["image_url", "url"])

      if is_binary(url) and url != "" do
        %{
          type: image["type"] || "image_url",
          url: url,
          mime_type: extract_mime_type(url)
        }
      else
        nil
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp parse_images(_), do: []

  defp extract_mime_type("data:" <> _ = data_url) do
    case Regex.run(~r/^data:([^;]+);base64,/, data_url, capture: :all_but_first) do
      [mime_type] -> mime_type
      _ -> "image/png"
    end
  end

  defp extract_mime_type(_url), do: "image/png"

  # Strip reasoning trace content from LLM responses, keeping only final text.
  #
  # Standard models: content is a plain string — pass through unchanged.
  # Anthropic extended thinking: content is an array of blocks like
  #   [%{"type" => "thinking", ...}, %{"type" => "text", "text" => "..."}]
  #   Filter to "text" blocks only, concatenate their text values.
  # DeepSeek R1: reasoning lives in a separate "reasoning_content" field
  #   which we never extract, so no action needed.
  defp extract_text_content(content) when is_binary(content), do: content
  defp extract_text_content(nil), do: nil

  defp extract_text_content(blocks) when is_list(blocks) do
    text =
      blocks
      |> Enum.filter(fn
        %{"type" => "text"} -> true
        _ -> false
      end)
      |> Enum.map_join(fn %{"text" => text} -> text end)

    case text do
      "" -> nil
      result -> result
    end
  end

  defp extract_text_content(_other), do: nil

  defp parse_usage(%{"usage" => usage}) when is_map(usage) do
    prompt_details = usage["prompt_tokens_details"] || %{}
    completion_details = usage["completion_tokens_details"] || %{}

    %{
      prompt_tokens: usage["prompt_tokens"] || 0,
      completion_tokens: usage["completion_tokens"] || 0,
      total_tokens: usage["total_tokens"] || 0,
      # prompt_tokens already includes cached_tokens — cached_tokens is a
      # subset, not additive. Useful for cache hit observability.
      cached_tokens: prompt_details["cached_tokens"] || 0,
      cache_write_tokens: prompt_details["cache_write_tokens"] || 0,
      audio_tokens: prompt_details["audio_tokens"] || 0,
      reasoning_tokens: completion_details["reasoning_tokens"] || 0,
      cost: usage["cost"]
    }
  end

  defp parse_usage(_), do: empty_usage()

  defp normalize_model_details(model) when is_map(model) do
    id = Map.get(model, "id")

    if is_binary(id) and id != "" do
      input_cost =
        model
        |> get_in(["pricing", "prompt"])
        |> format_price_per_million()

      output_cost =
        model
        |> get_in(["pricing", "completion"])
        |> format_price_per_million()

      %{
        id: id,
        name: to_string(Map.get(model, "name") || id),
        input_cost: input_cost,
        output_cost: output_cost,
        max_context_tokens: format_context_tokens(Map.get(model, "context_length"))
      }
    end
  end

  defp normalize_model_details(_), do: nil

  defp format_context_tokens(value) when is_integer(value) and value > 0,
    do: Integer.to_string(value)

  defp format_context_tokens(value) when is_binary(value) do
    case Integer.parse(value) do
      {tokens, _} when tokens > 0 -> Integer.to_string(tokens)
      _ -> "n/a"
    end
  end

  defp format_context_tokens(_), do: "n/a"

  defp format_price_per_million(value) when is_binary(value) do
    case Float.parse(value) do
      {price_per_token, _} when price_per_token >= 0 ->
        price_per_million = price_per_token * 1_000_000
        "$#{:erlang.float_to_binary(price_per_million, decimals: 2)} / 1M tokens"

      _ ->
        "n/a"
    end
  end

  defp format_price_per_million(value) when is_number(value) and value >= 0 do
    format_price_per_million(to_string(value))
  end

  defp format_price_per_million(_), do: "n/a"

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
      case extract_text_content(delta["content"]) do
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

  defp maybe_put_image_opt(image_opts, _key, nil, _validator), do: image_opts

  defp maybe_put_image_opt(image_opts, key, value, validator) do
    if validator.(value) do
      Map.put(image_opts, key, value)
    else
      image_opts
    end
  end

  defp valid_positive_integer?(value), do: is_integer(value) and value > 0
  defp valid_non_empty_string?(value), do: is_binary(value) and String.trim(value) != ""

  # --- HTTP Client ---

  defp do_request(body, override_key) do
    http = ConfigLoader.http_config()
    req = build_req_client(http, :request, override_key)
    Req.post(req, url: "/chat/completions", json: body)
  end

  defp build_req_client(http, mode, override_key) do
    timeout =
      case mode do
        :streaming -> http.streaming_timeout_ms
        :request -> http.request_timeout_ms
      end

    key = override_key || api_key()

    Req.new(
      base_url: base_url(),
      headers: [
        {"authorization", "Bearer #{key}"},
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
      cache_write_tokens: 0,
      audio_tokens: 0,
      reasoning_tokens: 0,
      cost: nil
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
