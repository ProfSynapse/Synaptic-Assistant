defmodule Assistant.Encryption.Cache do
  @moduledoc false

  use GenServer

  @table __MODULE__
  @prune_interval_ms 60_000

  def child_spec(opts \\ []) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]}
    }
  end

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec get(binary(), binary()) :: {:ok, binary()} | :miss
  def get(tenant_id, key) when is_binary(tenant_id) and is_binary(key) do
    composite_key = {tenant_id, key}

    case :ets.lookup(@table, composite_key) do
      [{^composite_key, value, expires_at}] ->
        if System.monotonic_time(:millisecond) < expires_at do
          {:ok, value}
        else
          # Expired entry — return :miss and let the periodic pruner clean it up.
          # We cannot delete here because the table is :protected (owner-write only).
          :miss
        end

      _ ->
        :miss
    end
  end

  @spec put(binary(), binary(), binary()) :: :ok
  def put(tenant_id, key, value)
      when is_binary(tenant_id) and is_binary(key) and is_binary(value) do
    GenServer.cast(__MODULE__, {:put, tenant_id, key, value})
  end

  @doc """
  Removes all cached DEKs for a given tenant (billing_account_id).
  Synchronous — blocks until the flush completes.
  """
  @spec flush_tenant(binary()) :: :ok
  def flush_tenant(tenant_id) when is_binary(tenant_id) do
    GenServer.call(__MODULE__, {:flush_tenant, tenant_id})
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :protected, :set, read_concurrency: true])

    config =
      Application.get_env(:assistant, :content_crypto, [])
      |> Keyword.get(:cache, [])

    state = %{
      ttl_ms: Keyword.get(config, :ttl_ms, 300_000),
      max_entries: Keyword.get(config, :max_entries, 10_000)
    }

    schedule_prune()
    {:ok, state}
  end

  @impl true
  def handle_cast({:put, tenant_id, key, value}, %{ttl_ms: ttl_ms, max_entries: max_entries} = state) do
    composite_key = {tenant_id, key}
    expires_at = System.monotonic_time(:millisecond) + ttl_ms
    :ets.insert(@table, {composite_key, value, expires_at})
    prune_if_needed(max_entries)
    {:noreply, state}
  end

  @impl true
  def handle_call({:flush_tenant, tenant_id}, _from, state) do
    :ets.match_delete(@table, {{tenant_id, :_}, :_, :_})
    {:reply, :ok, state}
  end

  @impl true
  def handle_info(:prune, state) do
    prune_expired()
    schedule_prune()
    {:noreply, state}
  end

  defp prune_if_needed(max_entries) do
    if :ets.info(@table, :size) > max_entries do
      prune_expired()
    end
  end

  defp prune_expired do
    now = System.monotonic_time(:millisecond)

    @table
    |> :ets.tab2list()
    |> Enum.each(fn {composite_key, _value, expires_at} ->
      if expires_at <= now do
        :ets.delete(@table, composite_key)
      end
    end)
  end

  defp schedule_prune do
    Process.send_after(self(), :prune, @prune_interval_ms)
  end
end
