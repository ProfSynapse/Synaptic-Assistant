defmodule Assistant.Policy.Rule do
  @moduledoc false

  alias Assistant.Schemas.PolicyRule

  @scope_rank %{"user" => 0, "workspace" => 1, "system" => 2}

  @doc """
  Returns `true` if the rule matches the given action descriptor.
  """
  @spec matches?(PolicyRule.t(), map()) :: boolean()
  def matches?(%PolicyRule{matchers: matchers}, action) when is_map(matchers) do
    Enum.all?(matchers, fn {key, value} ->
      action_value = Map.get(action, to_string(key))
      match_value?(action_value, value)
    end)
  end

  def matches?(_, _), do: true

  @doc """
  Ranking helper so user rules sort before workspace rules before system rules.
  """
  @spec scope_rank(PolicyRule.t()) :: integer()
  def scope_rank(%PolicyRule{scope_type: scope_type}) do
    Map.get(@scope_rank, scope_type, 3)
  end

  defp match_value?(value, matcher) when is_list(matcher) do
    Enum.member?(matcher, value)
  end

  defp match_value?(value, matcher), do: matcher == value
end
