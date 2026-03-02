# lib/assistant/integration_settings.ex — Context module for integration settings.
#
# Primary public API for reading, writing, and listing integration settings.
# Consumers call `get/1` to read a setting (replaces Application.get_env).
# Admin UI calls `put/3`, `delete/1`, and `list_all/0` for management.
#
# Read path: ETS cache → env var fallback → nil. Never hits the database.
# Write path: DB upsert (RLS) → ETS write-through → PubSub broadcast.
#
# Related files:
#   - lib/assistant/integration_settings/cache.ex (ETS GenServer)
#   - lib/assistant/integration_settings/registry.ex (key definitions)
#   - lib/assistant/schemas/integration_setting.ex (Ecto schema)

defmodule Assistant.IntegrationSettings do
  @moduledoc """
  Context module for admin-configurable integration settings.

  Provides a unified API for reading integration keys (API tokens, secrets, etc.)
  with a DB-first, env-var-fallback strategy. All values are encrypted at rest
  via Cloak AES-GCM.

  ## Read Path (Hot Path)

  `get/1` reads from the ETS cache first. On cache miss, falls through to
  `Application.get_env(:assistant, key)`. The database is **never** queried
  on the read path.

  ## Write Path

  `put/3` validates the key against the Registry, upserts into the database
  within an RLS-enabled transaction, updates the ETS cache (write-through),
  and broadcasts a PubSub event for multi-node invalidation.

  ## Nil Semantics

  - DB row exists → returns DB value
  - No DB row, env var set → returns env var value
  - No DB row, no env var → returns nil
  - Deleting a DB row reverts to env var behavior
  """

  alias Assistant.IntegrationSettings.Cache
  alias Assistant.IntegrationSettings.Registry
  alias Assistant.Repo
  alias Assistant.Schemas.IntegrationSetting

  require Logger

  @pubsub_topic "integration_settings:changed"

  # --- Read API (consumers call these) ---

  @doc """
  Get the value of an integration setting.

  Checks the ETS cache first, then falls back to `Application.get_env`.
  Returns `nil` if the key is not configured anywhere.

  This is the primary replacement for `Application.get_env(:assistant, key)`
  in consumer files.
  """
  @spec get(atom()) :: String.t() | nil
  def get(key) when is_atom(key) do
    case Cache.lookup(key) do
      {:ok, value} -> value
      :miss -> Application.get_env(:assistant, key)
    end
  end

  @doc """
  Returns `true` if the integration key has a value from any source (DB or env var).
  """
  @spec configured?(atom()) :: boolean()
  def configured?(key) when is_atom(key) do
    get(key) != nil
  end

  # --- Write API (admin UI calls these) ---

  @doc """
  Save an integration setting value.

  Validates the key against the Registry, upserts the encrypted value in the
  database (within an RLS transaction), updates the ETS cache, and broadcasts
  a PubSub event.

  The `admin_id` is the `settings_users.id` of the admin making the change,
  stored for audit purposes.

  SECURITY: The value is NEVER logged. Only the key name and admin email
  appear in log output.
  """
  @spec put(atom(), String.t() | nil, binary() | nil) ::
          {:ok, IntegrationSetting.t()} | {:error, Ecto.Changeset.t() | term()}
  def put(key, value, admin_id \\ nil) when is_atom(key) do
    if Registry.known_key?(key) do
      key_str = Atom.to_string(key)
      group = Registry.definition_for_key(key) |> Map.get(:group)

      attrs = %{
        key: key_str,
        value: value,
        group: group,
        updated_by_id: admin_id
      }

      result =
        with_admin_transaction(fn ->
          case Repo.get_by(IntegrationSetting, key: key_str) do
            nil ->
              %IntegrationSetting{}
              |> IntegrationSetting.changeset(attrs)
              |> Repo.insert()

            existing ->
              existing
              |> IntegrationSetting.changeset(attrs)
              |> Repo.update()
          end
        end)

      case result do
        {:ok, {:ok, setting}} ->
          Cache.put(key, value)
          broadcast_change(key)
          Logger.info("Integration setting updated", key: key_str, admin_id: admin_id)
          {:ok, setting}

        {:ok, {:error, changeset}} ->
          {:error, changeset}

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, :unknown_key}
    end
  end

  @doc """
  Delete an integration setting, reverting to the env var fallback.

  Removes the row from the database, invalidates the ETS cache entry, and
  broadcasts a PubSub event.
  """
  @spec delete(atom()) :: {:ok, :deleted} | {:ok, :not_found} | {:error, term()}
  def delete(key) when is_atom(key) do
    if Registry.known_key?(key) do
      key_str = Atom.to_string(key)

      result =
        with_admin_transaction(fn ->
          case Repo.get_by(IntegrationSetting, key: key_str) do
            nil ->
              :not_found

            setting ->
              case Repo.delete(setting) do
                {:ok, _deleted} -> :deleted
                {:error, changeset} -> {:error, changeset}
              end
          end
        end)

      case result do
        {:ok, :deleted} ->
          Cache.invalidate(key)
          broadcast_change(key)
          Logger.info("Integration setting deleted (reverted to env var)", key: key_str)
          {:ok, :deleted}

        {:ok, :not_found} ->
          {:ok, :not_found}

        {:ok, {:error, changeset}} ->
          {:error, changeset}

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, :unknown_key}
    end
  end

  # --- Query API (admin UI listing) ---

  @doc """
  List all integration settings with their current source and masked values.

  Returns one entry per Registry key, indicating whether the value comes from
  the database, an environment variable, or is not configured.

  Secret values are masked (showing only the last 4 characters). Non-secret
  values are returned in full.

  SECURITY: Raw secret values are NEVER returned by this function.
  """
  @spec list_all() :: [
          %{
            key: atom(),
            source: :db | :env | :none,
            group: String.t(),
            masked_value: String.t() | nil,
            is_secret: boolean(),
            label: String.t(),
            help: String.t()
          }
        ]
  def list_all do
    Registry.all_keys()
    |> Enum.map(fn key_def ->
      key = key_def.key
      is_secret = key_def.secret

      {source, raw_value} = resolve_source(key)

      %{
        key: key,
        source: source,
        group: key_def.group,
        masked_value: mask_value(raw_value, is_secret),
        is_secret: is_secret,
        label: key_def.label,
        help: key_def.help
      }
    end)
  end

  # --- Internal ---

  defp resolve_source(key) do
    case Cache.lookup(key) do
      {:ok, value} ->
        {:db, value}

      :miss ->
        case Application.get_env(:assistant, key) do
          nil -> {:none, nil}
          value -> {:env, value}
        end
    end
  end

  defp mask_value(nil, _is_secret), do: nil
  defp mask_value(value, false), do: value

  defp mask_value(value, true) when is_binary(value) do
    len = String.length(value)

    if len <= 4 do
      String.duplicate("*", len)
    else
      "****" <> String.slice(value, -4, 4)
    end
  end

  defp with_admin_transaction(fun) do
    Repo.transaction(fn ->
      case Repo.query("SET LOCAL app.is_admin = 'true'") do
        {:ok, _} -> fun.()
        {:error, reason} -> Repo.rollback({:rls_setup_failed, reason})
      end
    end)
  end

  defp broadcast_change(key) do
    Phoenix.PubSub.broadcast_from(
      Assistant.PubSub,
      self(),
      @pubsub_topic,
      %{key: key}
    )
  end
end
