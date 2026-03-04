defmodule Assistant.Integrations.Web.Robots do
  @moduledoc """
  Minimal robots.txt support for web fetches.
  """

  alias Assistant.Integrations.Web.UrlPolicy

  @spec allowed?(String.t(), keyword()) :: {:ok, boolean()} | {:error, term()}
  def allowed?(url, opts \\ []) do
    user_agent = Keyword.get(opts, :user_agent, default_user_agent())

    with {:ok, uri} <- UrlPolicy.validate(url),
         robots_url <- robots_url(uri),
         {:ok, body_or_status} <- fetch_robots(robots_url, user_agent) do
      case body_or_status do
        :allow ->
          {:ok, true}

        body when is_binary(body) ->
          {:ok, allowed_by_rules?(uri.path || "/", body, user_agent)}
      end
    end
  end

  def default_user_agent do
    Application.get_env(:assistant, :web_fetch_user_agent, "SynapticAssistantBot/1.0")
  end

  defp robots_url(%URI{} = uri) do
    uri
    |> Map.put(:path, "/robots.txt")
    |> Map.put(:query, nil)
    |> Map.put(:fragment, nil)
    |> URI.to_string()
  end

  defp fetch_robots(url, user_agent) do
    case Req.get(url, headers: [{"user-agent", user_agent}], receive_timeout: 5_000) do
      {:ok, %Req.Response{status: status}} when status in [404, 410] ->
        {:ok, :allow}

      {:ok, %Req.Response{status: status}} when status in [401, 403] ->
        {:ok, ""}

      {:ok, %Req.Response{status: status, body: body}} when status >= 200 and status < 300 ->
        {:ok, body_to_string(body)}

      {:ok, %Req.Response{status: _status}} ->
        {:ok, :allow}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp allowed_by_rules?(path, body, user_agent) do
    matching_rules =
      body
      |> parse_groups()
      |> Enum.filter(&group_matches?(&1.user_agents, user_agent))
      |> Enum.max_by(&group_specificity/1, fn -> %{rules: []} end)
      |> Map.get(:rules, [])

    decide(path, matching_rules)
  end

  defp decide(_path, []), do: true

  defp decide(path, rules) do
    matching =
      Enum.filter(rules, fn {_type, rule_path} ->
        rule_path != "" and String.starts_with?(path, rule_path)
      end)

    case Enum.max_by(matching, fn {_type, rule_path} -> String.length(rule_path) end, fn ->
           nil
         end) do
      {:allow, _} -> true
      {:disallow, _} -> false
      nil -> true
    end
  end

  defp parse_groups(body) do
    body
    |> String.split("\n")
    |> Enum.map(&strip_comment/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.reduce({[], nil}, &accumulate_rule/2)
    |> finalize_groups()
  end

  defp accumulate_rule(line, {groups, current}) do
    case String.split(line, ":", parts: 2) do
      [field, value] ->
        key = String.downcase(String.trim(field))
        trimmed = String.trim(value)

        case key do
          "user-agent" ->
            case current do
              %{rules: []} = group ->
                {groups, %{group | user_agents: group.user_agents ++ [String.downcase(trimmed)]}}

              %{rules: [_ | _]} = group ->
                {groups ++ [group], %{user_agents: [String.downcase(trimmed)], rules: []}}

              nil ->
                {groups, %{user_agents: [String.downcase(trimmed)], rules: []}}
            end

          "allow" ->
            {groups, add_rule(current, {:allow, normalize_rule_path(trimmed)})}

          "disallow" ->
            {groups, add_rule(current, {:disallow, normalize_rule_path(trimmed)})}

          _ ->
            {groups, current}
        end

      _ ->
        {groups, current}
    end
  end

  defp finalize_groups({groups, nil}), do: groups
  defp finalize_groups({groups, current}), do: groups ++ [current]

  defp add_rule(nil, rule), do: %{user_agents: ["*"], rules: [rule]}
  defp add_rule(group, rule), do: %{group | rules: group.rules ++ [rule]}

  defp normalize_rule_path(""), do: ""

  defp normalize_rule_path(path) do
    case URI.parse(path) do
      %URI{path: nil} -> path
      %URI{path: parsed_path} -> parsed_path
    end
  end

  defp group_matches?(user_agents, user_agent) do
    ua = String.downcase(user_agent)

    Enum.any?(user_agents, fn
      "*" -> true
      candidate -> String.contains?(ua, candidate)
    end)
  end

  defp group_specificity(group) do
    group.user_agents
    |> Enum.map(&String.length/1)
    |> Enum.max(fn -> 0 end)
  end

  defp strip_comment(line) do
    case String.split(line, "#", parts: 2) do
      [head | _] -> head
      _ -> line
    end
  end

  defp body_to_string(body) when is_binary(body), do: body
  defp body_to_string(body), do: inspect(body)
end
