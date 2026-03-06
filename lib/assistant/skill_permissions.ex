defmodule Assistant.SkillPermissions do
  @moduledoc """
  Skill permission gates.

  Global overrides are file-backed (`priv/config/skill_permissions.json`) and
  apply workspace-wide. User overrides are stored in the database and apply
  per user.

  Effective allow logic:

      global_enabled(skill) and user_enabled(skill, user_id) and connector_enabled(skill, user_id)

  The connector gate currently applies to HubSpot skills (`hubspot.*`) using
  per-user connector state.
  """

  require Logger

  alias Assistant.SettingsUserConnectorStates
  alias Assistant.Skills.Registry
  alias Assistant.UserSkillOverrides

  @default_permissions_rel_path "priv/config/skill_permissions.json"

  @spec list_permissions() :: [map()]
  def list_permissions do
    global_overrides = read_overrides()

    Registry.list_all()
    |> Enum.map(fn skill ->
      enabled = Map.get(global_overrides, skill.name, true)

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

  @spec list_permissions_for_user(String.t()) :: [map()]
  def list_permissions_for_user(user_id) when is_binary(user_id) do
    Registry.list_all()
    |> Enum.map(fn skill ->
      %{
        id: skill.name,
        domain: skill.domain,
        domain_label: domain_label(skill.domain),
        skill_label: skill_label(skill.name),
        enabled: enabled_for_user?(user_id, skill.name)
      }
    end)
    |> Enum.sort_by(&{&1.domain_label, &1.skill_label})
  end

  def list_permissions_for_user(_), do: list_permissions()

  @spec enabled?(String.t()) :: boolean()
  def enabled?(skill_name) when is_binary(skill_name) do
    enabled_for_user?(nil, skill_name)
  end

  def enabled?(_), do: false

  @spec enabled_for_user?(String.t() | nil, String.t()) :: boolean()
  def enabled_for_user?(user_id, skill_name) when is_binary(skill_name) do
    global_enabled = Map.get(read_overrides(), skill_name, true)

    user_enabled =
      UserSkillOverrides.enabled_for_user?(user_id, skill_name,
        default: true
      )

    connector_enabled = connector_enabled_for_skill?(user_id, skill_name)

    global_enabled and user_enabled and connector_enabled
  end

  def enabled_for_user?(_user_id, _skill_name), do: false

  @spec set_enabled(String.t(), boolean()) :: :ok | {:error, term()}
  def set_enabled(skill_name, enabled) when is_binary(skill_name) and is_boolean(enabled) do
    overrides = read_overrides()
    updated = Map.put(overrides, skill_name, enabled)
    write_overrides(updated)
  end

  @spec set_enabled_for_user(String.t(), String.t(), boolean()) ::
          {:ok, Assistant.Schemas.UserSkillOverride.t()} | {:error, Ecto.Changeset.t()} | {:error, :invalid}
  def set_enabled_for_user(user_id, skill_name, enabled)
      when is_binary(user_id) and is_binary(skill_name) and is_boolean(enabled) do
    UserSkillOverrides.set_enabled(user_id, skill_name, enabled)
  end

  def set_enabled_for_user(_user_id, _skill_name, _enabled), do: {:error, :invalid}

  @spec clear_user_override(String.t(), String.t()) :: :ok
  def clear_user_override(user_id, skill_name)
      when is_binary(user_id) and is_binary(skill_name) do
    UserSkillOverrides.clear_override(user_id, skill_name)
  end

  def clear_user_override(_user_id, _skill_name), do: :ok

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

  defp connector_enabled_for_skill?(user_id, "hubspot." <> _rest) do
    SettingsUserConnectorStates.enabled_for_user?(user_id, "hubspot", default: false)
  end

  defp connector_enabled_for_skill?(_user_id, _skill_name), do: true

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
    Application.get_env(
      :assistant,
      :skill_permissions_path,
      Application.app_dir(:assistant, @default_permissions_rel_path)
    )
  end
end
