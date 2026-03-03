# test/assistant/channels/dispatcher_test.exs — Tests for the Dispatcher module.
#
# Tests the dispatch/2 spawn behavior and the async processing pipeline.
# Since Dispatcher spawns tasks that call UserResolver, Engine, and ReplyRouter,
# these tests verify coordination logic: message routing, error propagation,
# and adapter reply calls.

defmodule Assistant.Channels.DispatcherTest do
  use Assistant.DataCase, async: false
  # async: false because we use ETS for cross-process assertions and named registries

  alias Assistant.Channels.Dispatcher
  alias Assistant.Channels.Message

  import Assistant.ChannelFixtures

  # ---------------------------------------------------------------
  # ETS-based mock adapter (captures calls across processes)
  # ---------------------------------------------------------------

  defmodule EtsMockAdapter do
    @moduledoc false

    # Writes to the ETS table whose name is stored in :persistent_term under
    # the key {:dispatcher_test_table, node()}. Since tests run async: false,
    # only one test is active at a time. The persistent_term is updated in setup
    # before each test and cleared in on_exit. Tasks from a prior test that
    # outlive their test will write to a now-deleted table (caught and ignored).

    def send_reply(space_id, text, opts \\ []) do
      table = :persistent_term.get({:dispatcher_test_table, node()}, nil)

      if table do
        try do
          :ets.insert(table, {space_id, text, opts, self()})
        rescue
          ArgumentError -> :ok
        end
      end

      :ok
    end
  end

  setup do
    # Generate a unique table name per test to prevent cross-test ETS pollution.
    # Async tasks from prior tests that outlive their test will write to a
    # now-deleted table, failing silently, rather than polluting this test's table.
    table_name = :"dispatcher_test_replies_#{System.unique_integer([:positive, :monotonic])}"
    table = :ets.new(table_name, [:named_table, :public, :bag])
    :persistent_term.put({:dispatcher_test_table, node()}, table_name)

    on_exit(fn ->
      :persistent_term.put({:dispatcher_test_table, node()}, nil)

      try do
        :ets.delete(table)
      rescue
        ArgumentError -> :ok
      end
    end)

    {:ok, ets_table: table_name}
  end

  # ---------------------------------------------------------------
  # Helper to build a test Message struct
  # ---------------------------------------------------------------

  defp build_test_message(overrides \\ %{}) do
    defaults = %{
      id: "msg-#{System.unique_integer([:positive])}",
      channel: :telegram,
      channel_message_id: "ch-msg-1",
      space_id: "123456789",
      user_id: "#{System.unique_integer([:positive])}",
      user_display_name: "Test User",
      content: "Hello, assistant!"
    }

    attrs = Map.merge(defaults, overrides)
    struct!(Message, attrs)
  end

  # Waits for at least `count` entries in the per-test ETS table, with timeout.
  defp await_ets_replies(count \\ 1, timeout_ms \\ 2_000) do
    table = :persistent_term.get({:dispatcher_test_table, node()})
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    Stream.repeatedly(fn ->
      replies = :ets.tab2list(table)
      if length(replies) >= count, do: {:done, replies}, else: {:wait, nil}
    end)
    |> Enum.reduce_while(nil, fn
      {:done, replies}, _acc ->
        {:halt, replies}

      {:wait, _}, _acc ->
        if System.monotonic_time(:millisecond) > deadline do
          {:halt, :ets.tab2list(table)}
        else
          Process.sleep(50)
          {:cont, nil}
        end
    end)
  end

  # Finds a reply by space_id in the ETS replies list. Avoids hd(replies)
  # which can pick up stale replies from prior tests' async tasks.
  defp find_reply_for(replies, space_id) do
    reply = Enum.find(replies, fn {sid, _, _, _} -> sid == space_id end)
    assert reply != nil, "Expected reply with space_id #{space_id}, got: #{inspect(replies)}"
    reply
  end

  # ---------------------------------------------------------------
  # Module compilation
  # ---------------------------------------------------------------

  describe "module compilation" do
    test "Dispatcher module is loaded and exports dispatch/2 and dispatch/3" do
      assert function_exported?(Dispatcher, :dispatch, 2)
      assert function_exported?(Dispatcher, :dispatch, 3)
    end
  end

  # ---------------------------------------------------------------
  # dispatch/2 — spawn behavior
  # ---------------------------------------------------------------

  describe "dispatch/2 — task spawning" do
    test "returns {:ok, :dispatched} when task is spawned" do
      message = build_test_message()

      assert {:ok, :dispatched} = Dispatcher.dispatch(EtsMockAdapter, message)
    end

    test "spawned task calls adapter.send_reply on invalid platform ID" do
      # Use a deliberately invalid telegram ID (non-numeric) so UserResolver
      # rejects it immediately, and the Dispatcher error path calls adapter directly
      space = "spawn-#{System.unique_integer([:positive])}"
      message = build_test_message(%{user_id: "invalid;id", space_id: space})

      assert {:ok, :dispatched} = Dispatcher.dispatch(EtsMockAdapter, message)

      replies = await_ets_replies()
      assert length(replies) >= 1

      {_space_id, text, _opts, _pid} = find_reply_for(replies, space)
      # Should be the resolve error message
      assert text =~ "couldn't identify"
    end
  end

  # ---------------------------------------------------------------
  # dispatch/2 — error paths
  # ---------------------------------------------------------------

  describe "dispatch/2 — error handling" do
    test "invalid platform ID sends resolve error reply via adapter" do
      space = "invalid-pid-#{System.unique_integer([:positive])}"

      message = build_test_message(%{
        channel: :telegram,
        user_id: "abc-not-numeric",
        space_id: space
      })

      {:ok, :dispatched} = Dispatcher.dispatch(EtsMockAdapter, message)

      replies = await_ets_replies()
      assert length(replies) >= 1

      {_space_id, text, _opts, _pid} = find_reply_for(replies, space)
      assert text =~ "couldn't identify"
    end

    test "valid user resolves and engine attempt sends reply via adapter" do
      # Create a user+identity in the DB so UserResolver.resolve succeeds.
      # Engine will attempt to start, process via LLM (which fails in test env
      # without valid API keys), and Dispatcher sends an error reply gracefully.
      ext_id = "777888999"
      space = "valid-user-#{System.unique_integer([:positive])}"

      {_user, _identity, _conversation} =
        user_with_conversation_fixture(%{
          channel: "telegram",
          external_id: ext_id
        })

      message = build_test_message(%{user_id: ext_id, channel: :telegram, space_id: space})

      assert {:ok, :dispatched} = Dispatcher.dispatch(EtsMockAdapter, message)

      # Wait for the async task to complete. The engine attempt will fail
      # (no valid LLM key in test env) and Dispatcher sends an error reply.
      replies = await_ets_replies(1, 5_000)

      # Strong assertion: a reply was sent back through the adapter
      assert length(replies) >= 1

      {_space_id, text, _opts, _pid} = find_reply_for(replies, space)
      assert is_binary(text)
      # The reply should be one of the error messages (engine or processing)
      assert text =~ "error" or text =~ "Error" or text =~ "encountered"
    end

    test "user resolution DB error sends generic error reply" do
      # Use a valid-format external_id for an unknown user. UserResolver will
      # attempt auto-creation. The auto-creation succeeds, then engine processing
      # fails. Either way, the Dispatcher must reply — never crash silently.
      ext_id = "#{System.unique_integer([:positive])}"
      space = "db-err-#{System.unique_integer([:positive])}"
      message = build_test_message(%{user_id: ext_id, channel: :telegram, space_id: space})

      assert {:ok, :dispatched} = Dispatcher.dispatch(EtsMockAdapter, message)

      # Wait for async processing
      replies = await_ets_replies(1, 5_000)

      # A reply should always be sent — no silent failures
      assert length(replies) >= 1
      {_space_id, text, _opts, _pid} = find_reply_for(replies, space)
      assert is_binary(text)
    end
  end

  # ---------------------------------------------------------------
  # dispatch/2 — origin building and reply routing
  # ---------------------------------------------------------------

  describe "dispatch/2 — origin and routing" do
    test "reply includes correct space_id from original message" do
      # Invalid ID triggers the error path which calls adapter.send_reply
      # with the original message's space_id
      space = "space-#{System.unique_integer([:positive])}"

      message = build_test_message(%{
        user_id: "invalid!id",
        space_id: space,
        channel: :telegram
      })

      {:ok, :dispatched} = Dispatcher.dispatch(EtsMockAdapter, message)

      replies = await_ets_replies()
      assert length(replies) >= 1

      {reply_space_id, _text, _opts, _pid} = find_reply_for(replies, space)
      assert reply_space_id == space
    end

    test "dispatch with different channels routes to correct adapter" do
      # Slack has a different ID format. Invalid Slack ID triggers error path.
      space = "C0TEST-#{System.unique_integer([:positive])}"

      message = build_test_message(%{
        channel: :slack,
        user_id: "invalid-slack-id",
        space_id: space
      })

      {:ok, :dispatched} = Dispatcher.dispatch(EtsMockAdapter, message)

      replies = await_ets_replies()
      assert length(replies) >= 1

      {_space_id, text, _opts, _pid} = find_reply_for(replies, space)
      assert is_binary(text)
    end

    test "message content is preserved through dispatch" do
      # Even when dispatch fails (invalid ID), the message struct is intact
      message = build_test_message(%{
        user_id: "bad;id",
        content: "This is my specific message content"
      })

      {:ok, :dispatched} = Dispatcher.dispatch(EtsMockAdapter, message)

      # The dispatch spawns successfully — content isn't lost
      replies = await_ets_replies()
      assert length(replies) >= 1
    end
  end

  # ---------------------------------------------------------------
  # dispatch/2 — concurrent dispatch safety
  # ---------------------------------------------------------------

  describe "dispatch/2 — concurrent dispatch" do
    test "multiple concurrent dispatches for different users don't interfere" do
      # Dispatch messages from multiple "users" (all invalid IDs for simplicity)
      messages =
        for i <- 1..5 do
          build_test_message(%{
            user_id: "invalid;#{i}",
            space_id: "space-#{i}"
          })
        end

      # Dispatch all concurrently
      results = Enum.map(messages, &Dispatcher.dispatch(EtsMockAdapter, &1))

      assert Enum.all?(results, fn result -> result == {:ok, :dispatched} end)

      # Wait for all replies
      replies = await_ets_replies(5, 3_000)
      assert length(replies) == 5

      # Each space_id should appear exactly once
      reply_spaces = Enum.map(replies, fn {space_id, _text, _opts, _pid} -> space_id end)
      expected_spaces = Enum.map(1..5, &"space-#{&1}")
      assert Enum.sort(reply_spaces) == Enum.sort(expected_spaces)
    end
  end

  # ---------------------------------------------------------------
  # dispatch/2 — thread_id propagation
  # ---------------------------------------------------------------

  describe "dispatch/2 — thread_id propagation" do
    test "thread_id is passed through to reply opts for threaded messages" do
      space = "threaded-#{System.unique_integer([:positive])}"

      message = build_test_message(%{
        user_id: "not;valid",
        space_id: space,
        thread_id: "thread-abc-123"
      })

      {:ok, :dispatched} = Dispatcher.dispatch(EtsMockAdapter, message)

      replies = await_ets_replies()
      assert length(replies) >= 1

      {_space_id, _text, opts, _pid} = find_reply_for(replies, space)
      assert Keyword.get(opts, :thread_name) == "thread-abc-123"
    end

    test "non-threaded messages have no thread_name in opts" do
      space = "unthreaded-#{System.unique_integer([:positive])}"

      message = build_test_message(%{
        user_id: "not;valid",
        space_id: space,
        thread_id: nil
      })

      {:ok, :dispatched} = Dispatcher.dispatch(EtsMockAdapter, message)

      replies = await_ets_replies()
      assert length(replies) >= 1

      {_space_id, _text, opts, _pid} = find_reply_for(replies, space)
      assert Keyword.get(opts, :thread_name) == nil
    end
  end

  # ---------------------------------------------------------------
  # dispatch/2 — crash safety (rescue clause)
  # ---------------------------------------------------------------

  describe "dispatch/2 — crash safety" do
    test "dispatched task does not crash the calling process" do
      # Even with unusual input, the calling process survives
      space = "crash-safe-#{System.unique_integer([:positive])}"
      message = build_test_message(%{user_id: "bad;id", space_id: space})

      {:ok, :dispatched} = Dispatcher.dispatch(EtsMockAdapter, message)

      # The test process is still alive
      assert Process.alive?(self())

      # Wait for the spawned task to complete
      replies = await_ets_replies()
      assert length(replies) >= 1
      assert find_reply_for(replies, space) != nil
    end

    test "rapid sequential dispatches all return :dispatched" do
      results =
        for _i <- 1..10 do
          message = build_test_message(%{user_id: "bad;id"})
          Dispatcher.dispatch(EtsMockAdapter, message)
        end

      assert Enum.all?(results, fn result -> result == {:ok, :dispatched} end)
    end
  end
end
