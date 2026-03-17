defmodule Assistant.Integrations.Web.HttpFetcher do
  @moduledoc """
  Deterministic HTTP fetcher with basic safety checks for public-web content.
  """

  alias Assistant.Integrations.Web.{Robots, UrlPolicy}
  alias Assistant.Policy
  alias Assistant.Schemas.PolicyRule

  @default_timeout_ms 10_000
  @default_max_bytes 1_000_000
  @default_max_redirects 5
  @redirect_statuses [301, 302, 303, 307, 308]
  @allowed_content_types [
    "text/html",
    "application/xhtml+xml",
    "text/plain",
    "application/json",
    "application/xml",
    "text/xml"
  ]

  @type fetch_result :: %{
          url: String.t(),
          final_url: String.t(),
          status: pos_integer(),
          content_type: String.t() | nil,
          fetched_at: DateTime.t(),
          body: binary(),
          headers: map()
        }

  @spec fetch(String.t(), keyword()) :: {:ok, fetch_result()} | {:error, term()}
  def fetch(url, opts \\ [])

  def fetch(url, opts) when is_binary(url) do
    timeout = Keyword.get(opts, :timeout, @default_timeout_ms)
    max_bytes = Keyword.get(opts, :max_bytes, @default_max_bytes)
    max_redirects = Keyword.get(opts, :max_redirects, @default_max_redirects)
    user_agent = Keyword.get(opts, :user_agent, Robots.default_user_agent())
    respect_robots? = Keyword.get(opts, :respect_robots, true)
    robots = Keyword.get(opts, :robots, Robots)
    url_policy = Keyword.get(opts, :url_policy, UrlPolicy)
    request_fun = Keyword.get(opts, :request_fun, &Req.get/2)

    with :ok <- authorize_web_fetch(url, opts),
         {:ok, uri} <- url_policy.validate(url),
         {:ok, response, final_uri} <-
           start_fetch(
             uri,
             timeout: timeout,
             user_agent: user_agent,
             respect_robots?: respect_robots?,
             robots: robots,
             url_policy: url_policy,
             request_fun: request_fun,
             max_redirects: max_redirects
           ),
         :ok <- validate_content_type(response),
         {:ok, body} <- encode_body(response.body),
         :ok <- validate_body_size(body, max_bytes) do
      {:ok,
       %{
         url: URI.to_string(uri),
         final_url: URI.to_string(final_uri),
         status: response.status,
         content_type: header(response.headers, "content-type"),
         fetched_at: DateTime.utc_now() |> DateTime.truncate(:second),
         body: body,
         headers: response.headers
       }}
    end
  end

  def fetch(_, _), do: {:error, :invalid_url}

  defp start_fetch(uri, opts) do
    timeout = Keyword.fetch!(opts, :timeout)
    user_agent = Keyword.fetch!(opts, :user_agent)
    respect_robots? = Keyword.fetch!(opts, :respect_robots?)
    robots = Keyword.fetch!(opts, :robots)
    url_policy = Keyword.fetch!(opts, :url_policy)
    request_fun = Keyword.fetch!(opts, :request_fun)
    max_redirects = Keyword.fetch!(opts, :max_redirects)

    do_fetch(uri,
      timeout: timeout,
      user_agent: user_agent,
      respect_robots?: respect_robots?,
      robots: robots,
      url_policy: url_policy,
      request_fun: request_fun,
      max_redirects: max_redirects,
      redirects_remaining: max_redirects
    )
  end

  defp do_fetch(uri, opts) when is_struct(uri, URI) do
    timeout = Keyword.fetch!(opts, :timeout)
    user_agent = Keyword.fetch!(opts, :user_agent)
    respect_robots? = Keyword.fetch!(opts, :respect_robots?)
    robots = Keyword.fetch!(opts, :robots)
    request_fun = Keyword.fetch!(opts, :request_fun)
    redirects_remaining = Keyword.fetch!(opts, :redirects_remaining)
    url_policy = Keyword.fetch!(opts, :url_policy)

    with :ok <- maybe_check_robots(uri, respect_robots?, user_agent, robots),
         {:ok, response} <- request_page(uri, timeout, user_agent, request_fun) do
      case response.status do
        status when status in 200..299 ->
          {:ok, response, uri}

        status when status in @redirect_statuses ->
          follow_redirect(uri, response, url_policy, opts, redirects_remaining)

        status ->
          {:error, {:http_error, status}}
      end
    end
  end

  defp maybe_check_robots(_uri, false, _user_agent, _robots), do: :ok

  defp maybe_check_robots(uri, true, user_agent, robots) do
    case robots.allowed?(URI.to_string(uri), user_agent: user_agent) do
      {:ok, true} -> :ok
      {:ok, false} -> {:error, :robots_disallowed}
      {:error, reason} -> {:error, {:robots_error, reason}}
    end
  end

  defp request_page(uri, timeout, user_agent, request_fun) do
    case request_fun.(URI.to_string(uri),
           headers: [{"user-agent", user_agent}, {"accept", accepted_content_types()}],
           receive_timeout: timeout,
           redirect: false
         ) do
      {:ok, %Req.Response{} = response} ->
        {:ok, response}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp follow_redirect(_uri, _response, _url_policy, opts, redirects_remaining)
       when redirects_remaining <= 0 do
    {:error, {:too_many_redirects, Keyword.fetch!(opts, :max_redirects)}}
  end

  defp follow_redirect(uri, response, url_policy, opts, redirects_remaining) do
    case header(response.headers, "location") do
      nil ->
        {:error, {:redirect_missing_location, response.status}}

      location ->
        next_uri = URI.merge(uri, location)

        with {:ok, validated_uri} <- url_policy.validate(URI.to_string(next_uri)) do
          do_fetch(
            validated_uri,
            Keyword.put(opts, :redirects_remaining, redirects_remaining - 1)
          )
        end
    end
  end

  defp validate_content_type(%Req.Response{headers: headers}) do
    content_type = header(headers, "content-type")

    if is_nil(content_type) or
         Enum.any?(@allowed_content_types, &String.starts_with?(content_type, &1)) do
      :ok
    else
      {:error, {:unsupported_content_type, content_type}}
    end
  end

  defp validate_body_size(body, max_bytes) when byte_size(body) <= max_bytes, do: :ok
  defp validate_body_size(_body, max_bytes), do: {:error, {:body_too_large, max_bytes}}

  defp encode_body(body) when is_binary(body), do: {:ok, body}
  defp encode_body(body) when is_map(body) or is_list(body), do: {:ok, Jason.encode!(body)}
  defp encode_body(_), do: {:error, :unsupported_body}

  defp accepted_content_types do
    Enum.join(@allowed_content_types, ", ")
  end

  defp authorize_web_fetch(url, opts) do
    action = build_web_fetch_action(url, opts)
    context = build_web_fetch_context(opts)
    policy_rules = Keyword.get(opts, :policy_rules)

    if policy_resolution_enabled?(context, policy_rules) and Code.ensure_loaded?(Policy) and
         function_exported?(Policy, :resolve_action, 2) do
      resolve_opts =
        [scope: context]
        |> maybe_put_opt(:rules, policy_rules)

      case Policy.resolve_action(action, resolve_opts) do
        {:ok, :deny, rule} ->
          {:error, {:policy_denied, policy_block_message(rule)}}

        {:ok, :ask, rule} ->
          {:error, {:policy_requires_approval, policy_block_message(rule)}}

        {:ok, _effect, _rule} ->
          :ok

        _ ->
          :ok
      end
    else
      :ok
    end
  end

  defp build_web_fetch_action(url, opts) do
    uri = URI.parse(url)

    if Code.ensure_loaded?(Policy.Action) do
      Policy.Action.web_fetch(url, opts)
    else
      %{
        resource_type: :web_fetch,
        host: uri.host || "",
        scheme: uri.scheme || "https",
        path: uri.path || "/",
        query: uri.query,
        user_id: opts[:user_id]
      }
    end
  end

  defp build_web_fetch_context(opts) do
    %{
      user_id: opts[:user_id],
      workspace_id: opts[:workspace_id],
      integration: opts[:integration],
      requester: opts[:requester]
    }
  end

  defp policy_resolution_enabled?(context, policy_rules) do
    is_list(policy_rules) or
      valid_policy_scope_id?(context[:user_id]) or
      valid_policy_scope_id?(context[:workspace_id])
  end

  defp maybe_put_opt(opts, _key, nil), do: opts
  defp maybe_put_opt(opts, key, value), do: Keyword.put(opts, key, value)

  defp valid_policy_scope_id?(value) when is_binary(value), do: String.trim(value) != ""
  defp valid_policy_scope_id?(_value), do: false

  defp policy_block_message(%PolicyRule{} = rule) do
    rule.reason || "Action blocked by workspace policy."
  end

  defp policy_block_message(%{message: message}) when is_binary(message), do: message
  defp policy_block_message(%{reason: reason}) when is_binary(reason), do: reason
  defp policy_block_message(%{}), do: "Action blocked by workspace policy."

  defp header(headers, name) do
    case headers[String.downcase(name)] do
      [value | _] -> value
      value when is_binary(value) -> value
      _ -> nil
    end
  end
end
