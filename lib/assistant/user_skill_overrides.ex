defmodule Assistant.UserSkillOverrides do
  @moduledoc """
  Context for per-user skill enable/disable overrides.
  """

  import Ecto.Query, warn: false

  alias Assistant.Repo
  alias Assistant.Schemas.UserSkillOverride

  @uuid_regex ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i

  @spec list_for_user(String.t()) :: [UserSkillOverride.t()]
  def list_for_user(user_id) when is_binary(user_id) do
    if valid_uuid?(user_id) do
      UserSkillOverride
      |> where([o], o.user_id == ^user_id)
      |> order_by([o], asc: o.skill_name)
      |> Repo.all()
    else
      []
    end
  end

  def list_for_user(_), do: []

  @spec overrides_map_for_user(String.t()) :: %{String.t() => boolean()}
  def overrides_map_for_user(user_id) when is_binary(user_id) do
    user_id
    |> list_for_user()
    |> Map.new(fn %UserSkillOverride{skill_name: skill_name, enabled: enabled} ->
      {skill_name, enabled}
    end)
  end

  def overrides_map_for_user(_), do: %{}

  @spec enabled_for_user?(String.t() | nil, String.t(), keyword()) :: boolean()
  def enabled_for_user?(user_id, skill_name, opts \\ []) do
    default = Keyword.get(opts, :default, true)

    cond do
      not is_binary(skill_name) or skill_name == "" ->
        false

      not is_binary(user_id) or user_id == "" ->
        default

      not valid_uuid?(user_id) ->
        default

      true ->
        case Repo.get_by(UserSkillOverride, user_id: user_id, skill_name: skill_name) do
          %UserSkillOverride{enabled: enabled} -> enabled
          nil -> default
        end
    end
  end

  @spec set_enabled(String.t(), String.t(), boolean()) ::
          {:ok, UserSkillOverride.t()} | {:error, Ecto.Changeset.t()} | {:error, :invalid}
  def set_enabled(user_id, skill_name, enabled)
      when is_binary(user_id) and is_binary(skill_name) and is_boolean(enabled) do
    if valid_uuid?(user_id) do
      attrs = %{
        user_id: user_id,
        skill_name: String.trim(skill_name),
        enabled: enabled
      }

      %UserSkillOverride{}
      |> UserSkillOverride.changeset(attrs)
      |> Repo.insert(
        on_conflict: {:replace, [:enabled, :updated_at]},
        conflict_target: [:user_id, :skill_name]
      )
    else
      {:error, :invalid}
    end
  end

  def set_enabled(_user_id, _skill_name, _enabled), do: {:error, :invalid}

  @spec clear_override(String.t(), String.t()) :: :ok
  def clear_override(user_id, skill_name) when is_binary(user_id) and is_binary(skill_name) do
    if valid_uuid?(user_id) do
      from(o in UserSkillOverride, where: o.user_id == ^user_id and o.skill_name == ^skill_name)
      |> Repo.delete_all()
    end

    :ok
  end

  def clear_override(_, _), do: :ok

  defp valid_uuid?(value) when is_binary(value) do
    Regex.match?(@uuid_regex, value)
  end

  defp valid_uuid?(_), do: false
end
