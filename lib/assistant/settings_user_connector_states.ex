defmodule Assistant.SettingsUserConnectorStates do
  @moduledoc """
  Context for per-user integration/connector state.

  A connector's workspace credentials are managed by admins in IntegrationSettings.
  This context tracks whether each user has the connector enabled for themselves.
  """

  import Ecto.Query, warn: false

  alias Assistant.Repo
  alias Assistant.Schemas.SettingsUserConnectorState

  @spec list_for_user(String.t()) :: [SettingsUserConnectorState.t()]
  def list_for_user(user_id) when is_binary(user_id) do
    SettingsUserConnectorState
    |> where([s], s.user_id == ^user_id)
    |> order_by([s], asc: s.integration_group)
    |> Repo.all()
  end

  def list_for_user(_), do: []

  @spec get_for_user(String.t(), String.t()) ::
          {:ok, SettingsUserConnectorState.t()} | {:error, :not_found}
  def get_for_user(user_id, integration_group)
      when is_binary(user_id) and is_binary(integration_group) do
    case Repo.get_by(SettingsUserConnectorState,
           user_id: user_id,
           integration_group: integration_group
         ) do
      %SettingsUserConnectorState{} = state -> {:ok, state}
      nil -> {:error, :not_found}
    end
  end

  def get_for_user(_, _), do: {:error, :not_found}

  @spec enabled_for_user?(String.t() | nil, String.t(), keyword()) :: boolean()
  def enabled_for_user?(user_id, integration_group, opts \\ []) do
    default = Keyword.get(opts, :default, true)

    cond do
      not is_binary(user_id) or user_id == "" ->
        default

      not is_binary(integration_group) or integration_group == "" ->
        default

      true ->
        case Repo.get_by(SettingsUserConnectorState,
               user_id: user_id,
               integration_group: integration_group
             ) do
          %SettingsUserConnectorState{enabled: enabled} -> enabled
          nil -> default
        end
    end
  end

  @spec set_enabled_for_user(String.t(), String.t(), boolean(), map()) ::
          {:ok, SettingsUserConnectorState.t()}
          | {:error, Ecto.Changeset.t()}
          | {:error, :invalid}
  def set_enabled_for_user(user_id, integration_group, enabled, metadata \\ %{})
  def set_enabled_for_user(user_id, integration_group, enabled, metadata)
      when is_binary(user_id) and is_binary(integration_group) and is_boolean(enabled) and
             is_map(metadata) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    attrs = %{
      user_id: user_id,
      integration_group: integration_group,
      enabled: enabled,
      metadata: metadata,
      connected_at: if(enabled, do: now, else: nil),
      disconnected_at: if(enabled, do: nil, else: now)
    }

    %SettingsUserConnectorState{}
    |> SettingsUserConnectorState.changeset(attrs)
    |> Repo.insert(
      on_conflict:
        {:replace, [:enabled, :metadata, :connected_at, :disconnected_at, :updated_at]},
      conflict_target: [:user_id, :integration_group]
    )
  end

  def set_enabled_for_user(_user_id, _integration_group, _enabled, _metadata),
    do: {:error, :invalid}

  @spec clear_for_user(String.t(), String.t()) :: :ok
  def clear_for_user(user_id, integration_group)
      when is_binary(user_id) and is_binary(integration_group) do
    from(s in SettingsUserConnectorState,
      where: s.user_id == ^user_id and s.integration_group == ^integration_group
    )
    |> Repo.delete_all()

    :ok
  end

  def clear_for_user(_, _), do: :ok
end
