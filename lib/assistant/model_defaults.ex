defmodule Assistant.ModelDefaults do
  @moduledoc """
  Database-backed default model selections by role.

  Global defaults are stored in `integration_settings`. Only admins may edit
  global defaults. Admins may also manage user-scoped overrides via the admin
  user detail view. User-scoped overrides live on `settings_users.model_defaults`.

  For backwards compatibility, legacy file-backed defaults are still read as a
  fallback until the new DB-backed keys are populated.
  """

  alias Assistant.Accounts
  alias Assistant.Accounts.SettingsUser
  alias Assistant.IntegrationSettings

  @default_rel_path "priv/config/model_defaults.json"

  @role_keys ~w(orchestrator sub_agent sentinel compaction fallback)

  @global_setting_keys %{
    "orchestrator" => :model_default_orchestrator,
    "sub_agent" => :model_default_sub_agent,
    "sentinel" => :model_default_sentinel,
    "compaction" => :model_default_compaction,
    "fallback" => :model_default_fallback
  }

  @role_atoms Enum.map(@role_keys, &String.to_atom/1)

  @type mode :: :global | :readonly

  @spec roles() :: [atom()]
  def roles, do: @role_atoms

  @spec role_keys() :: [String.t()]
  def role_keys, do: @role_keys

  @spec list_defaults() :: map()
  def list_defaults, do: global_defaults()

  @spec global_defaults() :: map()
  def global_defaults do
    Map.merge(legacy_defaults(), stored_global_defaults())
  end

  @spec user_defaults(SettingsUser.t() | nil) :: map()
  def user_defaults(%SettingsUser{model_defaults: defaults}), do: sanitize_defaults(defaults)
  def user_defaults(_), do: %{}

  @spec personal_defaults(SettingsUser.t() | nil) :: map()
  def personal_defaults(settings_user), do: user_defaults(settings_user)

  @spec effective_defaults(SettingsUser.t() | nil) :: map()
  def effective_defaults(%SettingsUser{is_admin: true}), do: global_defaults()

  def effective_defaults(%SettingsUser{} = settings_user),
    do: Map.merge(global_defaults(), user_defaults(settings_user))

  def effective_defaults(_), do: global_defaults()

  @spec mode(SettingsUser.t() | nil) :: mode()
  def mode(%SettingsUser{is_admin: true}), do: :global
  def mode(_), do: :readonly

  @spec editable?(SettingsUser.t() | nil) :: boolean()
  def editable?(settings_user), do: mode(settings_user) == :global

  @spec source_for(SettingsUser.t() | nil, atom() | String.t()) :: :global | :user | :system
  def source_for(settings_user, role) do
    with {:ok, role_key} <- normalize_role_key(role) do
      scoped_defaults =
        case settings_user do
          %SettingsUser{is_admin: true} -> %{}
          %SettingsUser{} -> user_defaults(settings_user)
          _ -> %{}
        end

      cond do
        Map.has_key?(scoped_defaults, role_key) -> :user
        Map.has_key?(global_defaults(), role_key) -> :global
        true -> :system
      end
    else
      :error -> :system
    end
  end

  @spec default_model_id(atom(), keyword()) :: String.t() | nil
  def default_model_id(role, opts \\ []) when is_atom(role) and is_list(opts) do
    with {:ok, role_key} <- normalize_role_key(role) do
      opts
      |> settings_user_from_opts()
      |> effective_defaults()
      |> Map.get(role_key)
      |> blank_to_nil()
    else
      :error -> nil
    end
  end

  @spec save_defaults(SettingsUser.t(), map()) :: :ok | {:error, term()}
  def save_defaults(%SettingsUser{is_admin: true} = settings_user, params) when is_map(params) do
    normalized = normalize_params(params)
    save_global_defaults(normalized, settings_user.id)
  end

  def save_defaults(_, _), do: {:error, :not_authorized}

  @spec save_defaults(SettingsUser.t(), SettingsUser.t(), map()) :: :ok | {:error, term()}
  def save_defaults(%SettingsUser{} = actor, %SettingsUser{} = target, params)
      when is_map(params) do
    normalized = normalize_params(params)

    cond do
      actor.id == target.id ->
        save_defaults(target, normalized)

      actor.is_admin and not target.is_admin ->
        save_user_defaults(target, normalized)

      true ->
        {:error, :not_authorized}
    end
  end

  defp save_user_defaults(%SettingsUser{} = settings_user, normalized) do
    overrides =
      Enum.reduce(@role_keys, %{}, fn role_key, acc ->
        case Map.get(normalized, role_key, "") do
          "" -> acc
          value -> Map.put(acc, role_key, value)
        end
      end)

    case Accounts.update_settings_user_model_defaults(settings_user, overrides) do
      {:ok, _settings_user} -> :ok
      {:error, _} = error -> error
    end
  end

  defp stored_global_defaults do
    Enum.reduce(@global_setting_keys, %{}, fn {role_key, setting_key}, acc ->
      case IntegrationSettings.get(setting_key) |> normalize_value() do
        nil -> acc
        value -> Map.put(acc, role_key, value)
      end
    end)
  end

  defp legacy_defaults do
    path = defaults_path()

    if File.exists?(path) do
      with {:ok, content} <- File.read(path),
           {:ok, decoded} <- Jason.decode(content),
           defaults when is_map(defaults) <- decoded["defaults"] do
        sanitize_defaults(defaults)
      else
        _ -> %{}
      end
    else
      %{}
    end
  end

  defp save_global_defaults(normalized, admin_id) do
    @global_setting_keys
    |> Enum.reduce_while(:ok, fn {role_key, setting_key}, :ok ->
      value = Map.get(normalized, role_key, "")

      result =
        if value == "" do
          IntegrationSettings.delete(setting_key)
        else
          IntegrationSettings.put(setting_key, value, admin_id)
        end

      case result do
        {:ok, _} -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp settings_user_from_opts(opts) do
    case Keyword.get(opts, :settings_user) do
      %SettingsUser{} = settings_user ->
        settings_user

      _ ->
        case Keyword.get(opts, :user_id) do
          user_id when is_binary(user_id) -> Accounts.get_settings_user_by_user_id(user_id)
          _ -> nil
        end
    end
  end

  defp normalize_params(params) do
    Enum.reduce(params, %{}, fn {role, model_id}, acc ->
      case normalize_role_key(role) do
        {:ok, role_key} -> Map.put(acc, role_key, normalize_value(model_id) || "")
        :error -> acc
      end
    end)
  end

  defp sanitize_defaults(defaults) do
    Enum.reduce(defaults, %{}, fn {role, model_id}, acc ->
      case normalize_role_key(role) do
        {:ok, role_key} ->
          case normalize_value(model_id) do
            nil -> acc
            value -> Map.put(acc, role_key, value)
          end

        :error ->
          acc
      end
    end)
  end

  defp normalize_role_key(role) when is_atom(role), do: normalize_role_key(Atom.to_string(role))

  defp normalize_role_key(role) when is_binary(role) do
    role_key = role |> String.trim()

    if role_key in @role_keys, do: {:ok, role_key}, else: :error
  end

  defp normalize_role_key(_), do: :error

  defp normalize_value(nil), do: nil

  defp normalize_value(value) do
    value
    |> to_string()
    |> String.trim()
    |> blank_to_nil()
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(value), do: value

  defp defaults_path do
    Application.get_env(
      :assistant,
      :model_defaults_path,
      Application.app_dir(:assistant, @default_rel_path)
    )
  end
end
