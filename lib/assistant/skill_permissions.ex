defmodule Assistant.SkillPermissions do
  @moduledoc """
  File-backed global skill permissions for user-friendly toggles in settings.
  """

  require Logger

  alias Assistant.Skills.Registry

  @default_permissions_path "config/skill_permissions.json"

  @spec list_permissions() :: [map()]
  def list_permissions do
    overrides = read_overrides()

    Registry.list_all()
    |> Enum.map(fn skill ->
      enabled = Map.get(overrides, skill.name, true)

      %{
        id: skill.name,
        domain: skill.domain,
        domain_label: domain_label(skill.domain),
        skill_label: skill_label(skill.name),
        enabled: enabled
      }
    end)
    |> Enum.sort_by(&{&1.domain_label, &1.skill_label})
  end

  @spec enabled?(String.t()) :: boolean()
  def enabled?(skill_name) when is_binary(skill_name) do
    Map.get(read_overrides(), skill_name, true)
  end

  @spec set_enabled(String.t(), boolean()) :: :ok | {:error, term()}
  def set_enabled(skill_name, enabled) when is_binary(skill_name) and is_boolean(enabled) do
    overrides = read_overrides()
    updated = Map.put(overrides, skill_name, enabled)
    write_overrides(updated)
  end

  @spec skill_label(String.t()) :: String.t()
  def skill_label(skill_name) when is_binary(skill_name) do
    case String.split(skill_name, ".", parts: 2) do
      [_domain, action] ->
        action
        |> String.replace("_", " ")
        |> String.split()
        |> Enum.map_join(" ", &String.capitalize/1)

      _ ->
        skill_name
    end
  end

  @spec domain_label(String.t()) :: String.t()
  def domain_label(domain) when is_binary(domain) do
    domain
    |> String.replace("_", " ")
    |> String.split()
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  defp read_overrides do
    path = permissions_path()

    if File.exists?(path) do
      case File.read(path) do
        {:ok, content} ->
          case Jason.decode(content) do
            {:ok, decoded} when is_map(decoded) ->
              Map.new(decoded, fn {k, v} -> {to_string(k), v == true} end)

            _ ->
              %{}
          end

        {:error, reason} ->
          Logger.warning("Failed to read skill permissions", reason: inspect(reason))
          %{}
      end
    else
      %{}
    end
  rescue
    exception ->
      Logger.warning("Failed to parse skill permissions", reason: Exception.message(exception))
      %{}
  end

  defp write_overrides(overrides) do
    path = permissions_path()
    File.mkdir_p!(Path.dirname(path))
    payload = Jason.encode_to_iodata!(overrides, pretty: true)

    case File.write(path, payload) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  rescue
    exception ->
      {:error, exception}
  end

  defp permissions_path do
    Application.get_env(:assistant, :skill_permissions_path, @default_permissions_path)
  end
end
