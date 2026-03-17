defmodule Assistant.Policy.Resolver do
  @moduledoc false

  alias Assistant.Policy.Rule
  alias Assistant.Schemas.PolicyRule

  @default_effect :allow
  @valid_effects %{"allow" => :allow, "ask" => :ask, "deny" => :deny}

  @doc """
  Resolves a descriptor into `{:ok, effect, matching_rule}`.
  """
  @spec resolve(map(), keyword()) :: {:ok, atom(), PolicyRule.t() | nil}
  def resolve(action, opts \\ []) do
    rules = Keyword.get(opts, :rules, [])
    scope = Keyword.get(opts, :scope, %{})
    resource_type = to_string(action["resource_type"] || action[:resource_type] || "")

    rules
    |> Enum.filter(& &1.enabled)
    |> Enum.sort_by(&{Rule.scope_rank(&1), &1.priority})
    |> Enum.reduce_while({:ok, @default_effect, nil}, fn rule, _ ->
      cond do
        not scope_matches?(rule, scope) ->
          {:cont, {:ok, @default_effect, nil}}

        not same_resource_type?(rule, resource_type) ->
          {:cont, {:ok, @default_effect, nil}}

        Rule.matches?(rule, action) ->
          {:halt, {:ok, effect_atom(rule.effect), rule}}

        true ->
          {:cont, {:ok, @default_effect, nil}}
      end
    end)
  end

  defp effect_atom(effect) do
    Map.get(@valid_effects, effect, @default_effect)
  end

  defp scope_matches?(%PolicyRule{scope_type: "system"}, _scope), do: true

  defp scope_matches?(%PolicyRule{scope_type: "workspace", scope_id: id}, scope) do
    match_scope?(scope[:workspace_id], id)
  end

  defp scope_matches?(%PolicyRule{scope_type: "user", scope_id: id}, scope) do
    match_scope?(scope[:user_id], id)
  end

  defp scope_matches?(_, _), do: false

  defp match_scope?(nil, _), do: false
  defp match_scope?(value, id) when is_binary(value) and is_binary(id), do: value == id
  defp match_scope?(_, _), do: false

  defp same_resource_type?(%PolicyRule{resource_type: type}, resource_type) do
    to_string(type) == resource_type
  end
end
