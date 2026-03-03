# lib/assistant/integration_settings/cache.ex — ETS cache for integration settings.
#
# GenServer that maintains an ETS table for fast, concurrent reads of integration
# settings. Warms from the database on init and subscribes to PubSub for
# invalidation when settings are updated via the admin UI.
#
# Related files:
#   - lib/assistant/integration_settings.ex (context module — primary consumer)
#   - lib/assistant/integration_settings/registry.ex (key definitions)
#   - lib/assistant/schemas/integration_setting.ex (Ecto schema)
#   - lib/assistant/application.ex (supervision tree — starts after Repo)

defmodule Assistant.IntegrationSettings.Cache do
  @moduledoc """
  ETS-backed cache for integration settings.

  Provides lock-free concurrent reads via a named ETS table. The GenServer
  coordinates cache warming (loading all DB rows into ETS on boot) and
  invalidation (removing stale entries when settings change).

  ## Boot Behaviour

  On `init/1`, warms ETS from the database using an RLS-enabled transaction.
  If the warm fails (e.g., DB not ready), the cache starts empty — reads fall
  through to `Application.get_env` in the context module. This is safe because
  the env var fallback produces identical behavior to pre-migration code.

  ## Invalidation

  Subscribes to `"integration_settings:changed"` PubSub topic. On receiving
  a message, deletes the specific key from ETS. The next `get/1` call will
  re-populate from the DB (via the context module's write-through) or fall
  through to the env var.
  """

  use GenServer

  require Logger

  @ets_table :integration_settings_cache
  @pubsub_topic "integration_settings:changed"

  # --- Public API (read from ETS, no GenServer call) ---

  @doc """
  Look up a key in the ETS cache.

  Returns `{:ok, value}` on hit or `:miss` if the key is not cached.
  """
  @spec lookup(atom()) :: {:ok, String.t()} | :miss
  def lookup(key) when is_atom(key) do
    case :ets.lookup(@ets_table, key) do
      [{^key, value}] -> {:ok, value}
      [] -> :miss
    end
  rescue
    ArgumentError -> :miss
  end

  @doc """
  Write-through: insert a key-value pair into the ETS cache.

  Called by the context module after a successful DB write.
  """
  @spec put(atom(), String.t()) :: :ok
  def put(key, value) when is_atom(key) do
    :ets.insert(@ets_table, {key, value})
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc """
  Invalidate (delete) a single key from the ETS cache.

  The next read for this key will miss and fall through to the env var fallback.
  """
  @spec invalidate(atom()) :: :ok
  def invalidate(key) when is_atom(key) do
    :ets.delete(@ets_table, key)
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc """
  Invalidate all keys in the ETS cache.
  """
  @spec invalidate_all() :: :ok
  def invalidate_all do
    :ets.delete_all_objects(@ets_table)
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc """
  Reload all integration settings from the database into ETS.

  Uses an RLS-enabled transaction to read all rows.
  """
  @spec warm() :: :ok | {:error, term()}
  def warm do
    GenServer.call(__MODULE__, :warm)
  end

  # --- GenServer ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    table = :ets.new(@ets_table, [:named_table, :set, :public, read_concurrency: true])
    Phoenix.PubSub.subscribe(Assistant.PubSub, @pubsub_topic)

    case do_warm(table) do
      :ok ->
        Logger.info("IntegrationSettings.Cache warmed successfully")
        {:ok, %{table: table}}

      {:error, reason} ->
        Logger.warning("IntegrationSettings.Cache warm failed, starting empty",
          reason: inspect(reason)
        )

        {:ok, %{table: table}}
    end
  end

  @impl true
  def handle_call(:warm, _from, %{table: table} = state) do
    case do_warm(table) do
      :ok -> {:reply, :ok, state}
      {:error, _reason} = error -> {:reply, error, state}
    end
  end

  @impl true
  def handle_info(%{key: key}, state) when is_atom(key) do
    if sandbox_mode?() do
      # In test mode with SQL Sandbox, skip DB re-warm to avoid sandbox
      # connection conflicts. Just invalidate; tests control ETS directly.
      :ets.delete(state.table, key)
    else
      # Re-warm specific key from DB instead of just deleting.
      # This ensures the cache stays populated after remote writes,
      # especially for keys without env var fallback.
      case warm_single_key(Atom.to_string(key), state.table) do
        :ok -> :ok
        :not_found -> :ets.delete(state.table, key)
      end
    end

    {:noreply, state}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # --- Internal ---

  # Returns true when the Repo is running in SQL Sandbox mode (test env).
  # Used to skip DB re-warming in PubSub handlers, preventing sandbox
  # connection conflicts that cascade into test failures.
  defp sandbox_mode? do
    Application.get_env(:assistant, Assistant.Repo)[:pool] == Ecto.Adapters.SQL.Sandbox
  end

  defp do_warm(table) do
    alias Assistant.Repo
    alias Assistant.Schemas.IntegrationSetting

    import Ecto.Query

    Repo.transaction(fn ->
      case Repo.query("SET LOCAL app.is_admin = 'true'") do
        {:ok, _} ->
          IntegrationSetting
          |> select([s], {s.key, s.value})
          |> Repo.all()
          |> Enum.each(fn {key_str, value} ->
            insert_cached_key(table, key_str, value)
          end)

        {:error, reason} ->
          Repo.rollback({:rls_setup_failed, reason})
      end
    end)
    |> case do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp insert_cached_key(table, key_str, value) do
    key_atom = String.to_existing_atom(key_str)
    :ets.insert(table, {key_atom, value})
  rescue
    ArgumentError ->
      Logger.warning("Unknown integration key in database, skipping", key: key_str)
  end

  defp warm_single_key(key_str, table) do
    alias Assistant.Repo
    alias Assistant.Schemas.IntegrationSetting

    import Ecto.Query

    Repo.transaction(fn ->
      case Repo.query("SET LOCAL app.is_admin = 'true'") do
        {:ok, _} ->
          IntegrationSetting
          |> where([s], s.key == ^key_str)
          |> select([s], {s.key, s.value})
          |> Repo.one()

        {:error, reason} ->
          Repo.rollback({:rls_setup_failed, reason})
      end
    end)
    |> case do
      {:ok, nil} ->
        :not_found

      {:ok, {key_s, value}} ->
        insert_cached_key(table, key_s, value)
        :ok

      {:error, _} ->
        :not_found
    end
  rescue
    _ -> :not_found
  end
end
