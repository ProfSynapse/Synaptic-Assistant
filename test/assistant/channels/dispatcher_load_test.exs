# test/assistant/channels/dispatcher_load_test.exs — Load tests for the Dispatcher.
#
# Tagged with :load so these are excluded from normal `mix test` runs.
# Run explicitly with: mix test --only load
#
# Tests the Dispatcher's ability to handle high concurrency and rapid sequential
# dispatch without crashes, using invalid platform IDs to exercise the
# TaskSupervisor spawn + adapter reply error path without requiring an Engine
# or LLM backend.

defmodule Assistant.Channels.DispatcherLoadTest do
  use Assistant.DataCase, async: false
  # async: false — shared ETS table for cross-process reply capture

  alias Assistant.Channels.Dispatcher
  alias Assistant.Channels.Message

  @moduletag :load

  # ---------------------------------------------------------------
  # ETS-based mock adapter (same pattern as dispatcher_test.exs)
  # ---------------------------------------------------------------

  defmodule LoadTestAdapter do
    @moduledoc false

    def send_reply(space_id, text, opts \\ []) do
      try do
        :ets.insert(:load_test_replies, {space_id, text, opts, self(), System.monotonic_time(:microsecond)})
      rescue
        ArgumentError -> :ok
      end

      :ok
    end
  end

  setup_all do
    table = :ets.new(:load_test_replies, [:named_table, :public, :bag])

    on_exit(fn ->
      try do
        :ets.delete(table)
      rescue
        ArgumentError -> :ok
      end
    end)

    :ok
  end

  setup do
    # Clear the table between tests to get accurate counts
    :ets.delete_all_objects(:load_test_replies)
    :ok
  end

  # ---------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------

  defp build_message(overrides \\ %{}) do
    defaults = %{
      id: "msg-#{System.unique_integer([:positive])}",
      channel: :telegram,
      channel_message_id: "ch-#{System.unique_integer([:positive])}",
      space_id: "load-#{System.unique_integer([:positive])}",
      user_id: "invalid;load;#{System.unique_integer([:positive])}",
      user_display_name: "Load User",
      content: "Load test message"
    }

    struct!(Message, Map.merge(defaults, overrides))
  end

  defp await_all_replies(expected_space_ids, timeout_ms \\ 10_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    expected = MapSet.new(expected_space_ids)

    Stream.repeatedly(fn ->
      all_entries = :ets.tab2list(:load_test_replies)
      found = MapSet.new(all_entries, fn {sid, _, _, _, _} -> sid end)

      if MapSet.subset?(expected, found) do
        {:done, all_entries}
      else
        {:wait, MapSet.size(found)}
      end
    end)
    |> Enum.reduce_while(nil, fn
      {:done, entries}, _acc ->
        {:halt, entries}

      {:wait, _count}, _acc ->
        if System.monotonic_time(:millisecond) > deadline do
          all = :ets.tab2list(:load_test_replies)
          found_ids = MapSet.new(all, fn {sid, _, _, _, _} -> sid end)
          missing = MapSet.difference(expected, found_ids)

          flunk(
            "Timed out: got #{MapSet.size(found_ids)}/#{MapSet.size(expected)} replies. " <>
              "Missing: #{inspect(Enum.take(MapSet.to_list(missing), 5))}..."
          )
        else
          Process.sleep(50)
          {:cont, nil}
        end
    end)
  end

  # ---------------------------------------------------------------
  # Test: 50 concurrent dispatches complete without crashes
  # ---------------------------------------------------------------

  describe "concurrent dispatch load" do
    @tag timeout: 30_000
    test "50 concurrent dispatches all complete with replies" do
      count = 50

      messages =
        for _i <- 1..count do
          build_message()
        end

      space_ids = Enum.map(messages, & &1.space_id)

      # Fire all dispatches concurrently using Task.async
      tasks =
        Enum.map(messages, fn msg ->
          Task.async(fn ->
            Dispatcher.dispatch(LoadTestAdapter, msg)
          end)
        end)

      # All dispatch calls should return {:ok, :dispatched}
      results = Task.await_many(tasks, 10_000)

      for result <- results do
        assert {:ok, :dispatched} = result
      end

      # Wait for all async reply tasks to complete
      replies = await_all_replies(space_ids)

      # Verify we got a reply for each dispatch
      reply_space_ids = MapSet.new(replies, fn {sid, _, _, _, _} -> sid end)

      for sid <- space_ids do
        assert MapSet.member?(reply_space_ids, sid),
               "Missing reply for space_id #{sid}"
      end
    end

    @tag timeout: 30_000
    test "50 concurrent dispatches for same channel don't crash TaskSupervisor" do
      count = 50

      messages =
        for _i <- 1..count do
          build_message(%{channel: :telegram})
        end

      space_ids = Enum.map(messages, & &1.space_id)

      # Dispatch all at once (not through Task.async — direct calls)
      results =
        Enum.map(messages, fn msg ->
          Dispatcher.dispatch(LoadTestAdapter, msg)
        end)

      assert Enum.all?(results, &(&1 == {:ok, :dispatched}))

      replies = await_all_replies(space_ids)
      assert length(replies) >= count
    end
  end

  # ---------------------------------------------------------------
  # Test: 100 rapid sequential dispatches
  # ---------------------------------------------------------------

  describe "sequential dispatch load" do
    @tag timeout: 30_000
    test "100 rapid sequential dispatches all return {:ok, :dispatched}" do
      count = 100

      {elapsed_us, results} =
        :timer.tc(fn ->
          for _i <- 1..count do
            msg = build_message()
            Dispatcher.dispatch(LoadTestAdapter, msg)
          end
        end)

      # All dispatches should succeed
      for result <- results do
        assert {:ok, :dispatched} = result
      end

      elapsed_ms = elapsed_us / 1_000

      # Dispatch calls should be fast (they just spawn a task).
      # 100 dispatches should complete well under 5 seconds total.
      assert elapsed_ms < 5_000,
             "100 sequential dispatches took #{Float.round(elapsed_ms, 1)}ms (expected < 5000ms)"
    end

    @tag timeout: 30_000
    test "100 sequential dispatches all produce replies" do
      count = 100

      messages =
        for _i <- 1..count do
          build_message()
        end

      space_ids = Enum.map(messages, & &1.space_id)

      for msg <- messages do
        assert {:ok, :dispatched} = Dispatcher.dispatch(LoadTestAdapter, msg)
      end

      # Wait for all async replies
      replies = await_all_replies(space_ids, 15_000)

      reply_space_ids = MapSet.new(replies, fn {sid, _, _, _, _} -> sid end)

      for sid <- space_ids do
        assert MapSet.member?(reply_space_ids, sid),
               "Missing reply for space_id #{sid}"
      end
    end
  end

  # ---------------------------------------------------------------
  # Test: Dispatch throughput measurement
  # ---------------------------------------------------------------

  describe "dispatch throughput" do
    @tag timeout: 30_000
    test "individual dispatch call completes under 10ms" do
      # Measure per-dispatch latency over 20 samples
      latencies =
        for _i <- 1..20 do
          msg = build_message()

          {elapsed_us, result} =
            :timer.tc(fn ->
              Dispatcher.dispatch(LoadTestAdapter, msg)
            end)

          assert {:ok, :dispatched} = result
          elapsed_us / 1_000
        end

      avg_ms = Enum.sum(latencies) / length(latencies)
      max_ms = Enum.max(latencies)

      # Each dispatch should be fast — it only spawns a task
      assert avg_ms < 10,
             "Average dispatch latency #{Float.round(avg_ms, 2)}ms exceeds 10ms threshold"

      # Allow some variance for GC pauses, but no individual call should be egregious
      assert max_ms < 100,
             "Max dispatch latency #{Float.round(max_ms, 2)}ms exceeds 100ms threshold"
    end

    @tag timeout: 30_000
    test "mixed channel concurrent dispatch" do
      channels = [:telegram, :slack, :discord, :google_chat]
      per_channel = 10

      messages =
        for channel <- channels, _i <- 1..per_channel do
          # Use invalid IDs per channel format to trigger error path
          invalid_id =
            case channel do
              :telegram -> "invalid;tg;#{System.unique_integer([:positive])}"
              :slack -> "invalid;sl;#{System.unique_integer([:positive])}"
              :discord -> "invalid;dc;#{System.unique_integer([:positive])}"
              :google_chat -> "invalid;gc;#{System.unique_integer([:positive])}"
            end

          build_message(%{channel: channel, user_id: invalid_id})
        end

      space_ids = Enum.map(messages, & &1.space_id)

      tasks =
        Enum.map(messages, fn msg ->
          Task.async(fn ->
            Dispatcher.dispatch(LoadTestAdapter, msg)
          end)
        end)

      results = Task.await_many(tasks, 10_000)
      assert Enum.all?(results, &(&1 == {:ok, :dispatched}))

      replies = await_all_replies(space_ids)
      assert length(replies) >= length(messages)
    end
  end
end
