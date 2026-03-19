defmodule Assistant.Policy.Action do
  @moduledoc """
  Normalizes metadata for actions that enter the policy resolver.
  """

  @type t :: map()

  @doc """
  Build an action descriptor for a skill call.
  """
  @spec skill_call(String.t(), keyword()) :: t()
  def skill_call(skill_name, opts \\ []) do
    raw =
      %{
        resource_type: :skill_call,
        skill: skill_name,
        domain: skill_name |> to_string() |> String.split(".", parts: 2) |> List.first(),
        action_class: Keyword.get(opts, :action_class),
        integration_group: Keyword.get(opts, :integration_group),
        user_id: Keyword.get(opts, :user_id)
      }

    raw
    |> Map.merge(keyword_to_string_map(opts, [:resource_type, :integration_group, :action_class]))
    |> normalize_keys()
  end

  def skill_call(skill_name, _skill_args, opts) when is_map(opts),
    do: skill_call(skill_name, opts)

  def skill_call(skill_name, _skill_args, _dispatch_params, _engine_state),
    do: skill_call(skill_name, [])

  def skill(skill_name, opts \\ []), do: skill_call(skill_name, opts)

  @doc """
  Build an action descriptor for a web fetch.
  """
  @spec web_fetch(String.t(), keyword()) :: t()
  def web_fetch(url, opts \\ []) do
    uri =
      case URI.parse(url || "") do
        %URI{host: nil} -> %URI{}
        parsed -> parsed
      end

    %{
      resource_type: :web_fetch,
      host: uri.host,
      scheme: uri.scheme,
      path: uri.path,
      action_class: Keyword.get(opts, :action_class),
      user_id: Keyword.get(opts, :user_id)
    }
    |> normalize_keys()
  end

  defp keyword_to_string_map(opts, keys) do
    opts
    |> Enum.filter(fn {k, _v} -> k in keys end)
    |> Map.new(fn {k, v} -> {to_string(k), v} end)
  end

  defp normalize_keys(map) do
    map
    |> Enum.map(fn {k, v} -> {to_string(k), v} end)
    |> Map.new()
  end
end
