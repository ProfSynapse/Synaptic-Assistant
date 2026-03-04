defmodule Assistant.Sync.WriteCoordinatorTest do
  use ExUnit.Case, async: false

  alias Assistant.Sync.WriteCoordinator

  setup do
    prev = Application.get_env(:assistant, :google_write_lease_enforcement)

    on_exit(fn ->
      if is_nil(prev) do
        Application.delete_env(:assistant, :google_write_lease_enforcement)
      else
        Application.put_env(:assistant, :google_write_lease_enforcement, prev)
      end
    end)

    :ok
  end

  test "retries transient errors and eventually succeeds" do
    attempts = :ets.new(:coordinator_attempts, [:set, :public])
    :ets.insert(attempts, {:count, 0})

    operation = fn ->
      [{:count, count}] = :ets.lookup(attempts, :count)
      :ets.insert(attempts, {:count, count + 1})

      if count < 1 do
        {:error, :timeout}
      else
        {:ok, :done}
      end
    end

    result =
      WriteCoordinator.execute(operation,
        classify_error: fn
          :timeout -> :transient
          _ -> :fatal
        end
      )

    assert {:ok, :done} = result
    assert [{:count, 2}] = :ets.lookup(attempts, :count)
  end

  test "does not retry fatal errors" do
    attempts = :ets.new(:coordinator_attempts_fatal, [:set, :public])
    :ets.insert(attempts, {:count, 0})

    operation = fn ->
      [{:count, count}] = :ets.lookup(attempts, :count)
      :ets.insert(attempts, {:count, count + 1})
      {:error, :boom}
    end

    assert {:error, :boom} =
             WriteCoordinator.execute(operation,
               classify_error: fn _ -> :fatal end
             )

    assert [{:count, 1}] = :ets.lookup(attempts, :count)
  end

  test "returns conflict without retry" do
    attempts = :ets.new(:coordinator_attempts_conflict, [:set, :public])
    :ets.insert(attempts, {:count, 0})

    operation = fn ->
      [{:count, count}] = :ets.lookup(attempts, :count)
      :ets.insert(attempts, {:count, count + 1})
      {:error, :conflict}
    end

    assert {:error, :conflict} =
             WriteCoordinator.execute(operation,
               classify_error: fn
                 :conflict -> :conflict
                 _ -> :fatal
               end
             )

    assert [{:count, 1}] = :ets.lookup(attempts, :count)
  end

  test "emits event_hook callbacks for successful operation" do
    operation = fn -> {:ok, :done} end

    assert {:ok, :done} =
             WriteCoordinator.execute(operation,
               event_hook: fn event -> send(self(), {:coordinator_event, event.type}) end
             )

    assert_received {:coordinator_event, :attempt}
    assert_received {:coordinator_event, :success}
    refute_received {:coordinator_event, :failure}
  end

  test "emits retry and failure events for transient then fatal flow" do
    attempts = :ets.new(:coordinator_attempts_events, [:set, :public])
    :ets.insert(attempts, {:count, 0})

    operation = fn ->
      [{:count, count}] = :ets.lookup(attempts, :count)
      :ets.insert(attempts, {:count, count + 1})

      if count == 0 do
        {:error, :timeout}
      else
        {:error, :boom}
      end
    end

    assert {:error, :boom} =
             WriteCoordinator.execute(operation,
               classify_error: fn
                 :timeout -> :transient
                 _ -> :fatal
               end,
               event_hook: fn event -> send(self(), {:coordinator_event, event.type}) end
             )

    assert_received {:coordinator_event, :attempt}
    assert_received {:coordinator_event, :retry}
    assert_received {:coordinator_event, :failure}
  end
end
