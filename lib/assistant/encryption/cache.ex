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

  @spec get(binary()) :: {:ok, binary()} | :miss
  def get(key) when is_binary(key) do
    case :ets.lookup(@table, key) do
      [{^key, value, expires_at}] ->
        if System.monotonic_time(:millisecond) < expires_at do
          {:ok, value}
        else
          :ets.delete(@table, key)
          :miss
        end

      _ ->
        :miss
    end
  end

  @spec put(binary(), binary()) :: :ok
  def put(key, value) when is_binary(key) and is_binary(value) do
    GenServer.cast(__MODULE__, {:put, key, value})
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])

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
  def handle_cast({:put, key, value}, %{ttl_ms: ttl_ms, max_entries: max_entries} = state) do
    expires_at = System.monotonic_time(:millisecond) + ttl_ms
    :ets.insert(@table, {key, value, expires_at})
    prune_if_needed(max_entries)
    {:noreply, state}
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
    |> Enum.each(fn {key, _value, expires_at} ->
      if expires_at <= now do
        :ets.delete(@table, key)
      end
    end)
  end

  defp schedule_prune do
    Process.send_after(self(), :prune, @prune_interval_ms)
  end
end
