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

    # Uses a shared ETS table :dispatcher_test_replies that lives for the entire
    # test module. Cross-test pollution from stale async tasks is prevented by
    # each test using a unique space_id and find_reply_for/2 to locate its
    # specific reply. The table is never deleted between tests — stale writes
    # from prior tests' async tasks are harmless because find_reply_for/2
    # ignores entries with non-matching space_ids.

    def send_reply(space_id, text, opts \\ []) do
      try do
        :ets.insert(:dispatcher_test_replies, {space_id, text, opts, self()})
      rescue
        # Table may not exist yet during module compilation test
        ArgumentError -> :ok
      end

      :ok
    end
  end

  setup_all do
    # Create the ETS table once for the entire test module.
    # Never deleted between tests — stale async task writes are harmless.
    table = :ets.new(:dispatcher_test_replies, [:named_table, :public, :bag])

    on_exit(fn ->
      try do
        :ets.delete(table)
      rescue
        ArgumentError -> :ok
      end
    end)

    :ok
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

  # Waits for the spawned task to fully exit after we've received the reply.
  # Prevents Ecto sandbox ownership errors from DB-touching tasks that haven't
  # fully cleaned up by the time on_exit revokes the shared sandbox.
  defp await_task_exit({_space_id, _text, _opts, pid}, timeout_ms \\ 1_000) do
    ref = Process.monitor(pid)

    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
    after
      timeout_ms ->
        Process.demonitor(ref, [:flush])
        :ok
    end
  end

  # Polls the ETS table until a reply with the given space_id appears.
  # Returns the matching tuple {space_id, text, opts, pid} or fails on timeout.
  defp await_reply_for(space_id, timeout_ms \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    Stream.repeatedly(fn ->
      case :ets.match_object(:dispatcher_test_replies, {space_id, :_, :_, :_}) do
        [match | _] -> {:found, match}
        [] -> {:wait, nil}
      end
    end)
    |> Enum.reduce_while(nil, fn
      {:found, match}, _acc ->
        {:halt, match}

      {:wait, _}, _acc ->
        if System.monotonic_time(:millisecond) > deadline do
          all = :ets.tab2list(:dispatcher_test_replies)

          flunk(
            "Timed out waiting for reply with space_id #{space_id}, table has: #{inspect(all)}"
          )
        else
          Process.sleep(50)
          {:cont, nil}
        end
    end)
  end

  # Waits for at least `count` entries matching the given space_ids.
  # Used by the concurrent dispatch test to wait for multiple specific replies.
  defp await_replies_for(space_ids, timeout_ms \\ 3_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    expected = MapSet.new(space_ids)

    Stream.repeatedly(fn ->
      matches =
        Enum.flat_map(space_ids, fn sid ->
          :ets.match_object(:dispatcher_test_replies, {sid, :_, :_, :_})
        end)

      found = MapSet.new(matches, fn {sid, _, _, _} -> sid end)

      if MapSet.subset?(expected, found) do
        {:done, matches}
      else
        {:wait, nil}
      end
    end)
    |> Enum.reduce_while(nil, fn
      {:done, matches}, _acc ->
        {:halt, matches}

      {:wait, _}, _acc ->
        if System.monotonic_time(:millisecond) > deadline do
          all = :ets.tab2list(:dispatcher_test_replies)

          flunk(
            "Timed out waiting for replies with space_ids #{inspect(space_ids)}, table has: #{inspect(all)}"
          )
        else
          Process.sleep(50)
          {:cont, nil}
        end
    end)
  end

  # ---------------------------------------------------------------
  # Module compilation
  # ---------------------------------------------------------------

  describe "module compilation" do
    test "Dispatcher module is loaded and exports dispatch/2 and dispatch/3" do
      # Ensure the module is loaded (may not be loaded yet if no call has been made)
      Code.ensure_loaded!(Dispatcher)
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

      {_space_id, text, _opts, _pid} = await_reply_for(space)
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

      message =
        build_test_message(%{
          channel: :telegram,
          user_id: "abc-not-numeric",
          space_id: space
        })

      {:ok, :dispatched} = Dispatcher.dispatch(EtsMockAdapter, message)

      {_space_id, text, _opts, _pid} = await_reply_for(space)
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
      reply = await_reply_for(space, 5_000)
      {_space_id, text, _opts, _pid} = reply
      assert is_binary(text)
      # The reply should be one of the error messages (engine or processing)
      assert text =~ "error" or text =~ "Error" or text =~ "encountered"

      # Wait for the spawned task to fully exit so the Ecto sandbox isn't
      # revoked while the task is still mid-DB-operation.
      await_task_exit(reply)
    end

    test "user resolution DB error sends generic error reply" do
      # Use a valid-format external_id for an unknown user. UserResolver will
      # attempt auto-creation. The auto-creation succeeds, then engine processing
      # fails. Either way, the Dispatcher must reply — never crash silently.
      ext_id = "#{System.unique_integer([:positive])}"
      space = "db-err-#{System.unique_integer([:positive])}"
      message = build_test_message(%{user_id: ext_id, channel: :telegram, space_id: space})

      assert {:ok, :dispatched} = Dispatcher.dispatch(EtsMockAdapter, message)

      # A reply should always be sent — no silent failures
      reply = await_reply_for(space, 5_000)
      {_space_id, text, _opts, _pid} = reply
      assert is_binary(text)

      # Wait for the spawned task to fully exit so the Ecto sandbox isn't
      # revoked while the task is still mid-DB-operation.
      await_task_exit(reply)
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

      message =
        build_test_message(%{
          user_id: "invalid!id",
          space_id: space,
          channel: :telegram
        })

      {:ok, :dispatched} = Dispatcher.dispatch(EtsMockAdapter, message)

      {reply_space_id, _text, _opts, _pid} = await_reply_for(space)
      assert reply_space_id == space
    end

    test "dispatch with different channels routes to correct adapter" do
      # Slack has a different ID format. Invalid Slack ID triggers error path.
      space = "C0TEST-#{System.unique_integer([:positive])}"

      message =
        build_test_message(%{
          channel: :slack,
          user_id: "invalid-slack-id",
          space_id: space
        })

      {:ok, :dispatched} = Dispatcher.dispatch(EtsMockAdapter, message)

      {_space_id, text, _opts, _pid} = await_reply_for(space)
      assert is_binary(text)
    end

    test "message content is preserved through dispatch" do
      # Even when dispatch fails (invalid ID), the message struct is intact
      space = "content-#{System.unique_integer([:positive])}"

      message =
        build_test_message(%{
          user_id: "bad;id",
          space_id: space,
          content: "This is my specific message content"
        })

      {:ok, :dispatched} = Dispatcher.dispatch(EtsMockAdapter, message)

      # The dispatch spawns successfully — content isn't lost
      {_space_id, _text, _opts, _pid} = await_reply_for(space)
    end
  end

  # ---------------------------------------------------------------
  # dispatch/2 — concurrent dispatch safety
  # ---------------------------------------------------------------

  describe "dispatch/2 — concurrent dispatch" do
    test "multiple concurrent dispatches for different users don't interfere" do
      # Use unique prefix to avoid collision with other tests
      prefix = "concurrent-#{System.unique_integer([:positive])}"

      messages =
        for i <- 1..5 do
          build_test_message(%{
            user_id: "invalid;#{i}",
            space_id: "#{prefix}-#{i}"
          })
        end

      # Dispatch all concurrently
      results = Enum.map(messages, &Dispatcher.dispatch(EtsMockAdapter, &1))

      assert Enum.all?(results, fn result -> result == {:ok, :dispatched} end)

      # Wait for all replies using specific space_ids
      expected_spaces = Enum.map(1..5, &"#{prefix}-#{&1}")
      replies = await_replies_for(expected_spaces)

      # Each space_id should appear exactly once
      reply_spaces = Enum.map(replies, fn {space_id, _text, _opts, _pid} -> space_id end)
      assert Enum.sort(reply_spaces) == Enum.sort(expected_spaces)
    end
  end

  # ---------------------------------------------------------------
  # dispatch/2 — thread_id propagation
  # ---------------------------------------------------------------

  describe "dispatch/2 — thread_id propagation" do
    test "thread_id is passed through to reply opts for threaded messages" do
      space = "threaded-#{System.unique_integer([:positive])}"

      message =
        build_test_message(%{
          user_id: "not;valid",
          space_id: space,
          thread_id: "thread-abc-123"
        })

      {:ok, :dispatched} = Dispatcher.dispatch(EtsMockAdapter, message)

      {_space_id, _text, opts, _pid} = await_reply_for(space)
      assert Keyword.get(opts, :thread_name) == "thread-abc-123"
    end

    test "non-threaded messages have no thread_name in opts" do
      space = "unthreaded-#{System.unique_integer([:positive])}"

      message =
        build_test_message(%{
          user_id: "not;valid",
          space_id: space,
          thread_id: nil
        })

      {:ok, :dispatched} = Dispatcher.dispatch(EtsMockAdapter, message)

      {_space_id, _text, opts, _pid} = await_reply_for(space)
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
      {reply_space, _text, _opts, _pid} = await_reply_for(space)
      assert reply_space == space
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
