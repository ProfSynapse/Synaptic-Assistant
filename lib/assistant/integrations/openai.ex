defmodule Assistant.Integrations.OpenAI do
  @moduledoc """
  OpenAI API client implementing the LLM client behaviour.

  Supports chat completions for text + tool-calling and a lightweight API-key
  validation call used by Settings BYOK flows.
  """

  @behaviour Assistant.Behaviours.LLMClient

  require Logger

  alias Assistant.Accounts
  alias Assistant.Config.Loader, as: ConfigLoader

  @base_url "https://api.openai.com/v1"
  @oauth_default_client_id "app_EMoamEEZ73f0CkXaXp7hrann"
  @oauth_default_token_url "https://auth.openai.com/oauth/token"
  @codex_default_endpoint "https://chatgpt.com/backend-api/codex/responses"

  @impl true
  def chat_completion(messages, opts \\ []) do
    if oauth_auth?(opts) do
      oauth_chat_completion(messages, opts)
    else
      with {:ok, body} <- build_request_body(messages, opts) do
        case do_request(body, Keyword.get(opts, :api_key)) do
          {:ok, %{status: 200, body: response_body}} ->
            parse_completion(response_body)

          {:ok, %{status: 429} = response} ->
            retry_after = extract_retry_after(response)
            {:error, {:rate_limited, retry_after}}

          {:ok, %{status: status, body: resp_body}} when status >= 400 ->
            error_message = get_in(resp_body, ["error", "message"]) || "Unknown error"
            {:error, {:api_error, status, error_message}}

          {:error, %Req.TransportError{reason: reason}} ->
            {:error, {:connection_error, reason}}

          {:error, reason} ->
            {:error, {:request_failed, reason}}
        end
      end
    end
  end

  @impl true
  def streaming_completion(messages, callback, opts \\ []) do
    if oauth_auth?(opts) do
      oauth_streaming_completion(messages, callback, opts)
    else
      with {:ok, base_body} <- build_request_body(messages, opts) do
        body =
          base_body
          |> Map.put(:stream, true)
          |> Map.put(:stream_options, %{include_usage: true})

        Process.put(:openai_stream_usage, nil)

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
            final_usage = Process.delete(:openai_stream_usage) || empty_usage()
            {:ok, final_usage}

          {:ok, %{status: 429} = response} ->
            Process.delete(:openai_stream_usage)
            retry_after = extract_retry_after(response)
            {:error, {:rate_limited, retry_after}}

          {:ok, %{status: status, body: resp_body}} when status >= 400 ->
            Process.delete(:openai_stream_usage)
            error_message = get_in(resp_body, ["error", "message"]) || "Unknown error"
            {:error, {:api_error, status, error_message}}

          {:error, reason} ->
            Process.delete(:openai_stream_usage)
            {:error, {:request_failed, reason}}
        end
      end
    end
  end

  @doc """
  Validates an OpenAI API key by listing visible models.
  """
  @spec validate_api_key(String.t()) :: :ok | {:error, term()}
  def validate_api_key(api_key) when is_binary(api_key) and api_key != "" do
    http = ConfigLoader.http_config()
    req = build_req_client(http, :request, api_key)

    case Req.get(req, url: "/models") do
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
  Lists OpenAI model IDs visible to the provided API key.
  """
  @spec list_models(String.t()) :: {:ok, [String.t()]} | {:error, term()}
  def list_models(api_key) when is_binary(api_key) and api_key != "" do
    http = ConfigLoader.http_config()
    req = build_req_client(http, :request, api_key)

    case Req.get(req, url: "/models") do
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
  Returns the known set of Codex-compatible model IDs available via ChatGPT OAuth.
  """
  @spec codex_model_ids() :: [String.t()]
  def codex_model_ids do
    [
      "gpt-5.3-codex",
      "gpt-5.2-codex",
      "gpt-5.2",
      "gpt-5.1-codex",
      "gpt-5.1-codex-max",
      "gpt-5.1-codex-mini"
    ]
  end

  @doc false
  def build_request_body(messages, opts) do
    case Keyword.fetch(opts, :model) do
      {:ok, model} ->
        body =
          %{model: model, messages: sanitize_messages(messages)}
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

  defp sanitize_messages(messages) when is_list(messages) do
    Enum.map(messages, fn
      %{content: content} = msg when is_list(content) ->
        sanitized =
          content
          |> Enum.map(fn
            %{} = part -> Map.delete(part, :cache_control) |> Map.delete("cache_control")
            other -> other
          end)

        %{msg | content: sanitized}

      msg ->
        msg
    end)
  end

  defp sanitize_messages(other), do: other

  defp maybe_add_tools(body, opts) do
    case Keyword.get(opts, :tools) do
      nil -> body
      [] -> body
      tools -> Map.put(body, :tools, Assistant.Integrations.OpenRouter.sort_tools(tools))
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

  defp parse_completion(body) do
    with %{"choices" => [choice | _]} <- body,
         %{"message" => message, "finish_reason" => finish_reason} <- choice do
      {:ok,
       %{
         id: body["id"],
         model: body["model"],
         content: extract_text_content(message["content"]),
         tool_calls: parse_tool_calls(message),
         finish_reason: finish_reason,
         usage: parse_usage(body)
       }}
    else
      _ ->
        Logger.error("OpenAI unexpected response format", body: inspect(body))
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

  defp extract_text_content(_), do: nil

  defp parse_usage(%{"usage" => usage}) when is_map(usage) do
    prompt_details = usage["prompt_tokens_details"] || %{}
    completion_details = usage["completion_tokens_details"] || %{}

    %{
      prompt_tokens: usage["prompt_tokens"] || 0,
      completion_tokens: usage["completion_tokens"] || 0,
      total_tokens: usage["total_tokens"] || 0,
      cached_tokens: prompt_details["cached_tokens"] || 0,
      cache_write_tokens: prompt_details["cache_write_tokens"] || 0,
      audio_tokens: prompt_details["audio_tokens"] || 0,
      reasoning_tokens: completion_details["reasoning_tokens"] || 0,
      cost: usage["cost"]
    }
  end

  defp parse_usage(_), do: empty_usage()

  defp handle_sse_line("data: [DONE]", _callback), do: :ok

  defp handle_sse_line("data: " <> json, callback) do
    case Jason.decode(json) do
      {:ok, chunk} ->
        parsed = parse_stream_chunk(chunk)
        if parsed[:usage], do: Process.put(:openai_stream_usage, parsed[:usage])
        callback.(parsed)

      {:error, _} ->
        :ok
    end
  end

  defp handle_sse_line(_, _callback), do: :ok

  defp parse_stream_chunk(chunk) do
    delta =
      chunk
      |> get_in(["choices", Access.at(0), "delta"])
      |> case do
        nil -> %{}
        d -> d
      end

    finish_reason = get_in(chunk, ["choices", Access.at(0), "finish_reason"])

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

  defp oauth_chat_completion(messages, opts) do
    with {:ok, auth} <- oauth_auth_from_opts(opts),
         {:ok, auth} <- maybe_refresh_oauth_auth(auth, opts),
         {:ok, body} <- build_codex_request_body(messages, opts),
         {:ok, state} <- codex_stream_request(body, auth, nil) do
      tool_calls = codex_state_tool_calls(state)
      finish_reason = state.finish_reason || if(tool_calls != [], do: "tool_calls", else: "stop")

      {:ok,
       %{
         id: nil,
         model: Keyword.get(opts, :model),
         content: blank_to_nil(state.content),
         tool_calls: tool_calls,
         finish_reason: finish_reason,
         usage: state.usage || empty_usage()
       }}
    end
  end

  defp oauth_streaming_completion(messages, callback, opts) do
    with {:ok, auth} <- oauth_auth_from_opts(opts),
         {:ok, auth} <- maybe_refresh_oauth_auth(auth, opts),
         {:ok, body} <- build_codex_request_body(messages, opts),
         {:ok, state} <- codex_stream_request(body, auth, callback) do
      final_usage = state.usage || empty_usage()
      {:ok, final_usage}
    end
  end

  defp oauth_auth?(opts) do
    case Keyword.get(opts, :openai_auth) do
      %{auth_type: "oauth"} -> true
      %{"auth_type" => "oauth"} -> true
      _ -> false
    end
  end

  defp oauth_auth_from_opts(opts) do
    case Keyword.get(opts, :openai_auth) do
      %{} = auth ->
        access_token = auth_value(auth, :access_token)
        account_id = auth_value(auth, :account_id) || extract_account_id_from_token(access_token)
        refresh_token = auth_value(auth, :refresh_token)
        expires_at = auth_value(auth, :expires_at)

        cond do
          not is_binary(access_token) or access_token == "" ->
            {:error, :missing_oauth_access_token}

          not is_binary(account_id) or account_id == "" ->
            {:error, :missing_oauth_account_id}

          true ->
            {:ok,
             %{
               auth_type: "oauth",
               access_token: access_token,
               refresh_token: refresh_token,
               account_id: account_id,
               expires_at: normalize_expiry(expires_at)
             }}
        end

      _ ->
        {:error, :missing_oauth_auth}
    end
  end

  defp maybe_refresh_oauth_auth(auth, opts) do
    if oauth_token_expired?(auth.expires_at) and is_binary(auth.refresh_token) and
         auth.refresh_token != "" do
      with {:ok, tokens} <- refresh_oauth_access_token(auth.refresh_token),
           {:ok, updated_auth} <- apply_refreshed_oauth(auth, tokens, opts) do
        {:ok, updated_auth}
      end
    else
      {:ok, auth}
    end
  end

  defp refresh_oauth_access_token(refresh_token) do
    form = %{
      "grant_type" => "refresh_token",
      "refresh_token" => refresh_token,
      "client_id" => oauth_client_id()
    }

    case Req.post(oauth_token_url(), form: form) do
      {:ok, %Req.Response{status: 200, body: %{"access_token" => access_token} = body}}
      when is_binary(access_token) and access_token != "" ->
        {:ok, body}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:openai_refresh_failed, status, body}}

      {:error, reason} ->
        {:error, {:openai_refresh_http_error, reason}}
    end
  end

  defp apply_refreshed_oauth(auth, tokens, opts) do
    expires_at =
      case tokens["expires_in"] do
        seconds when is_integer(seconds) and seconds > 0 ->
          DateTime.utc_now() |> DateTime.add(seconds, :second) |> DateTime.truncate(:second)

        _ ->
          auth.expires_at
      end

    updated_auth = %{
      auth_type: "oauth",
      access_token: tokens["access_token"],
      refresh_token: tokens["refresh_token"] || auth.refresh_token,
      account_id:
        extract_account_id_from_tokens(tokens) || auth.account_id ||
          extract_account_id_from_token(tokens["access_token"]),
      expires_at: expires_at
    }

    persist_refreshed_oauth(updated_auth, opts)
    {:ok, updated_auth}
  end

  defp persist_refreshed_oauth(auth, opts) do
    case Keyword.get(opts, :user_id) do
      user_id when is_binary(user_id) and user_id != "" ->
        _ =
          Accounts.save_openai_oauth_credentials_for_user(user_id, %{
            access_token: auth.access_token,
            refresh_token: auth.refresh_token,
            account_id: auth.account_id,
            expires_at: auth.expires_at
          })

        :ok

      _ ->
        :ok
    end
  end

  defp oauth_token_expired?(%DateTime{} = expires_at) do
    DateTime.compare(expires_at, DateTime.add(DateTime.utc_now(), 60, :second)) != :gt
  end

  defp oauth_token_expired?(_), do: false

  defp build_codex_request_body(messages, opts) do
    case Keyword.fetch(opts, :model) do
      {:ok, model} ->
        sanitized = sanitize_messages(messages)
        instructions = extract_codex_instructions(sanitized)
        input = codex_input_messages(sanitized)

        body =
          %{
            model: model,
            input: input,
            stream: true,
            store: false
          }
          |> maybe_put_instructions(instructions)
          |> maybe_add_codex_tools(opts)
          |> maybe_add_codex_tool_choice(opts)
          |> maybe_add_parallel_tool_calls(opts)

        {:ok, body}

      :error ->
        {:error, :no_model_specified}
    end
  end

  defp extract_codex_instructions(messages) do
    messages
    |> Enum.filter(
      &(Map.get(&1, :role) in ["system", :system] or Map.get(&1, "role") == "system")
    )
    |> Enum.map(&message_text/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
    |> blank_to_nil()
  end

  defp codex_input_messages(messages) do
    messages
    |> Enum.reject(
      &(Map.get(&1, :role) in ["system", :system] or Map.get(&1, "role") == "system")
    )
    |> Enum.map(fn msg ->
      %{
        role: normalize_role(Map.get(msg, :role) || Map.get(msg, "role")),
        content: message_text(msg)
      }
    end)
    |> Enum.reject(&(blank_to_nil(&1.content) == nil))
  end

  defp message_text(%{} = msg) do
    content = Map.get(msg, :content) || Map.get(msg, "content")

    cond do
      is_binary(content) ->
        content

      is_list(content) ->
        content
        |> Enum.map(fn
          %{"text" => text} when is_binary(text) -> text
          %{text: text} when is_binary(text) -> text
          %{"content" => text} when is_binary(text) -> text
          %{content: text} when is_binary(text) -> text
          other when is_binary(other) -> other
          _ -> ""
        end)
        |> Enum.join("")
        |> String.trim()

      true ->
        ""
    end
  end

  defp normalize_role(role) when role in [:assistant, "assistant"], do: "assistant"
  defp normalize_role(role) when role in [:tool, "tool"], do: "tool"
  defp normalize_role(_), do: "user"

  defp maybe_put_instructions(body, nil), do: body
  defp maybe_put_instructions(body, instructions), do: Map.put(body, :instructions, instructions)

  defp maybe_add_codex_tools(body, opts) do
    case Keyword.get(opts, :tools) do
      nil -> body
      [] -> body
      tools -> Map.put(body, :tools, Assistant.Integrations.OpenRouter.sort_tools(tools))
    end
  end

  defp maybe_add_codex_tool_choice(body, opts) do
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

  defp codex_stream_request(body, auth, callback) do
    Process.put(:openai_codex_state, initial_codex_state())

    stream_handler = fn {:data, data}, {req, resp} ->
      data
      |> String.split("\n")
      |> Enum.each(&handle_codex_sse_line(&1, callback))

      {:cont, {req, resp}}
    end

    http = ConfigLoader.http_config()
    req = build_codex_req_client(http, auth)

    case Req.post(req, url: codex_endpoint(), json: body, into: stream_handler) do
      {:ok, %{status: 200}} ->
        {:ok, finalize_codex_state(Process.delete(:openai_codex_state) || initial_codex_state())}

      {:ok, %{status: status, body: resp_body}} ->
        Process.delete(:openai_codex_state)
        error_message = get_in(resp_body, ["error", "message"]) || "Unknown error"
        {:error, {:api_error, status, error_message}}

      {:error, reason} ->
        Process.delete(:openai_codex_state)
        {:error, {:request_failed, reason}}
    end
  end

  defp build_codex_req_client(http, auth) do
    Req.new(
      headers: [
        {"authorization", "Bearer #{auth.access_token}"},
        {"chatgpt-account-id", auth.account_id},
        {"originator", oauth_originator()},
        {"user-agent", oauth_user_agent()},
        {"content-type", "application/json"}
      ],
      retry: :safe_transient,
      max_retries: http.max_retries,
      retry_delay: fn retry_count ->
        exponential_backoff(retry_count, http.base_backoff_ms, http.max_backoff_ms)
      end,
      receive_timeout: http.streaming_timeout_ms
    )
  end

  defp initial_codex_state do
    %{
      content: "",
      tool_calls: %{},
      usage: empty_usage(),
      finish_reason: nil
    }
  end

  defp handle_codex_sse_line("data: [DONE]", _callback), do: :ok

  defp handle_codex_sse_line("data: " <> json, callback) do
    case Jason.decode(json) do
      {:ok, chunk} ->
        delta = parse_codex_stream_chunk(chunk)
        merge_codex_state(delta)

        if is_function(callback, 1) do
          maybe_emit_codex_delta(callback, delta)
        end

      _ ->
        :ok
    end
  end

  defp handle_codex_sse_line(_, _callback), do: :ok

  defp maybe_emit_codex_delta(callback, delta) do
    if is_binary(delta[:content]) and delta[:content] != "" do
      callback.(%{content: delta[:content]})
    end

    if is_list(delta[:tool_calls]) and delta[:tool_calls] != [] do
      callback.(%{tool_calls: delta[:tool_calls]})
    end

    if delta[:finish_reason] do
      callback.(%{finish_reason: delta[:finish_reason]})
    end
  end

  defp parse_codex_stream_chunk(chunk) do
    result = %{}

    result =
      case extract_codex_delta_text(chunk) do
        nil -> result
        text -> Map.put(result, :content, text)
      end

    result =
      case extract_codex_tool_calls(chunk) do
        [] -> result
        tool_calls -> Map.put(result, :tool_calls, tool_calls)
      end

    usage = chunk["usage"] || get_in(chunk, ["response", "usage"])

    result =
      if is_map(usage) do
        Map.put(result, :usage, parse_codex_usage(usage))
      else
        result
      end

    finish_reason =
      get_in(chunk, ["choices", Access.at(0), "finish_reason"]) ||
        chunk["finish_reason"] ||
        if(chunk["type"] in ["response.completed", "response.done"], do: "stop", else: nil)

    if is_binary(finish_reason), do: Map.put(result, :finish_reason, finish_reason), else: result
  end

  defp extract_codex_delta_text(chunk) do
    cond do
      is_binary(chunk["delta"]) ->
        blank_to_nil(chunk["delta"])

      is_binary(get_in(chunk, ["delta", "text"])) ->
        blank_to_nil(get_in(chunk, ["delta", "text"]))

      is_binary(get_in(chunk, ["delta", "content"])) ->
        blank_to_nil(get_in(chunk, ["delta", "content"]))

      is_binary(chunk["output_text"]) ->
        blank_to_nil(chunk["output_text"])

      is_binary(get_in(chunk, ["response", "output_text", "delta"])) ->
        blank_to_nil(get_in(chunk, ["response", "output_text", "delta"]))

      true ->
        delta =
          chunk
          |> get_in(["choices", Access.at(0), "delta"])
          |> case do
            nil -> %{}
            d -> d
          end

        extract_text_content(delta["content"])
    end
  end

  defp extract_codex_tool_calls(chunk) do
    cond do
      chunk["type"] in ["response.output_item.added", "response.output_item.done"] ->
        chunk
        |> Map.get("item")
        |> parse_codex_function_call_item()
        |> wrap_list()

      true ->
        chunk
        |> get_in(["choices", Access.at(0), "delta", "tool_calls"])
        |> case do
          nil -> []
          tcs when is_list(tcs) -> tcs
          _ -> []
        end
    end
  end

  defp parse_codex_function_call_item(%{"type" => "function_call"} = item) do
    name = item["name"] || get_in(item, ["function", "name"])
    args = item["arguments"] || get_in(item, ["function", "arguments"]) || ""

    if is_binary(name) and name != "" do
      %{
        id: item["id"] || item["call_id"] || "call_#{System.unique_integer([:positive])}",
        type: "function",
        function: %{
          name: name,
          arguments: if(is_binary(args), do: args, else: Jason.encode!(args))
        }
      }
    end
  end

  defp parse_codex_function_call_item(_), do: nil

  defp parse_codex_usage(usage) when is_map(usage) do
    %{
      prompt_tokens: usage["input_tokens"] || usage["prompt_tokens"] || 0,
      completion_tokens: usage["output_tokens"] || usage["completion_tokens"] || 0,
      total_tokens:
        usage["total_tokens"] ||
          (usage["input_tokens"] || usage["prompt_tokens"] || 0) +
            (usage["output_tokens"] || usage["completion_tokens"] || 0),
      cached_tokens: get_in(usage, ["prompt_tokens_details", "cached_tokens"]) || 0,
      cache_write_tokens: get_in(usage, ["prompt_tokens_details", "cache_write_tokens"]) || 0,
      audio_tokens: get_in(usage, ["prompt_tokens_details", "audio_tokens"]) || 0,
      reasoning_tokens: get_in(usage, ["completion_tokens_details", "reasoning_tokens"]) || 0,
      cost: usage["cost"]
    }
  end

  defp merge_codex_state(delta) do
    state = Process.get(:openai_codex_state) || initial_codex_state()

    content = state.content <> (delta[:content] || "")

    tool_calls =
      (delta[:tool_calls] || [])
      |> Enum.reduce(state.tool_calls, fn tc, acc ->
        id = Map.get(tc, :id) || Map.get(tc, "id") || "call_#{System.unique_integer([:positive])}"
        existing = Map.get(acc, id)

        merged =
          if existing do
            existing_args = get_in(existing, [:function, :arguments]) || ""
            incoming_args = get_in(tc, [:function, :arguments]) || ""

            put_in(existing, [:function, :arguments], existing_args <> incoming_args)
          else
            normalize_tool_call(tc, id)
          end

        Map.put(acc, id, merged)
      end)

    usage = delta[:usage] || state.usage
    finish_reason = delta[:finish_reason] || state.finish_reason

    Process.put(
      :openai_codex_state,
      %{
        state
        | content: content,
          tool_calls: tool_calls,
          usage: usage,
          finish_reason: finish_reason
      }
    )
  end

  defp finalize_codex_state(state) do
    %{state | content: String.trim(state.content)}
  end

  defp codex_state_tool_calls(state) do
    state.tool_calls
    |> Map.values()
    |> Enum.reject(&is_nil/1)
  end

  defp normalize_tool_call(tc, id) do
    name = get_in(tc, [:function, :name]) || get_in(tc, ["function", "name"]) || "unknown"
    args = get_in(tc, [:function, :arguments]) || get_in(tc, ["function", "arguments"]) || ""

    %{
      id: id,
      type: "function",
      function: %{
        name: name,
        arguments: if(is_binary(args), do: args, else: Jason.encode!(args))
      }
    }
  end

  defp wrap_list(nil), do: []
  defp wrap_list(item), do: [item]

  defp auth_value(auth, key) when is_map(auth) do
    Map.get(auth, key) || Map.get(auth, Atom.to_string(key))
  end

  defp normalize_expiry(%DateTime{} = expires_at), do: expires_at

  defp normalize_expiry(%NaiveDateTime{} = expires_at),
    do: DateTime.from_naive!(expires_at, "Etc/UTC")

  defp normalize_expiry(_), do: nil

  defp extract_account_id_from_tokens(tokens) when is_map(tokens) do
    ["id_token", "access_token"]
    |> Enum.map(&Map.get(tokens, &1))
    |> Enum.find_value(&extract_account_id_from_token/1)
  end

  defp extract_account_id_from_tokens(_), do: nil

  defp extract_account_id_from_token(token) when is_binary(token) do
    with [_, payload, _] <- String.split(token, ".", parts: 3),
         {:ok, decoded} <- Base.url_decode64(payload, padding: false),
         {:ok, claims} <- Jason.decode(decoded),
         true <- is_map(claims) do
      claims["chatgpt_account_id"] ||
        get_in(claims, ["https://api.openai.com/auth", "chatgpt_account_id"]) ||
        get_in(claims, ["organizations", Access.at(0), "id"])
    else
      _ -> nil
    end
  end

  defp extract_account_id_from_token(_), do: nil

  defp oauth_client_id do
    Application.get_env(:assistant, :openai_oauth_client_id, @oauth_default_client_id)
  end

  defp oauth_token_url do
    Application.get_env(:assistant, :openai_oauth_token_url, @oauth_default_token_url)
  end

  defp codex_endpoint do
    Application.get_env(:assistant, :openai_codex_api_endpoint, @codex_default_endpoint)
  end

  defp oauth_originator do
    Application.get_env(:assistant, :openai_oauth_originator, "synaptic-assistant")
  end

  defp oauth_user_agent do
    Application.get_env(:assistant, :openai_oauth_user_agent, "synaptic-assistant/1.0")
  end

  defp blank_to_nil(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: trimmed
  end

  defp blank_to_nil(_), do: nil

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

  defp api_key do
    Application.fetch_env!(:assistant, :openai_api_key)
  end

  defp base_url do
    Application.get_env(:assistant, :openai_base_url, @base_url)
  end
end
