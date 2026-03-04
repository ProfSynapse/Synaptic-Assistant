# test/assistant/channels/dispatch_integration_test.exs — Integration tests for the
# full dispatch pipeline: webhook → dispatch → resolve → engine → reply.
#
# Tagged with :integration so these are excluded from normal `mix test` runs.
# Run explicitly with: mix test --only integration
#
# Tests the full pipeline stages with real DB users/identities and mock adapters.
# The Engine is started via DynamicSupervisor; LLM calls fail in test env
# (no real API key), so tests verify the error propagation path and that
# the Dispatcher always delivers a reply — never drops messages silently.
#
# For tests that need to verify the happy path (Engine produces a response),
# a fake Engine GenServer is registered under the user_id to bypass the LLM.

defmodule Assistant.Channels.DispatchIntegrationTest do
  use Assistant.DataCase, async: false
  # async: false — named registries, ETS tables, DynamicSupervisor, Mox global

  import Mox

  alias Assistant.Channels.{Dispatcher, Message, UserResolver}
  alias Assistant.Schemas.{Conversation, User, UserIdentity}

  import Assistant.ChannelFixtures

  @moduletag :integration
  @moduletag timeout: 60_000

  # ---------------------------------------------------------------
  # ETS-based mock adapter for capturing replies across processes
  # ---------------------------------------------------------------

  defmodule IntegrationAdapter do
    @moduledoc false

    def send_reply(space_id, text, opts \\ []) do
      try do
        :ets.insert(:integration_test_replies, {space_id, text, opts, self()})
      rescue
        ArgumentError -> :ok
      end

      :ok
    end
  end

  # ---------------------------------------------------------------
  # Fake Engine — a simple GenServer that returns canned responses
  # without requiring LLM. Registered in the EngineRegistry under
  # the user_id so Dispatcher.process_and_reply finds it.
  # ---------------------------------------------------------------

  defmodule FakeEngine do
    @moduledoc false
    use GenServer

    def start_link(user_id, opts \\ []) do
      GenServer.start_link(__MODULE__, opts,
        name: {:via, Elixir.Registry, {Assistant.Orchestrator.EngineRegistry, user_id}}
      )
    end

    @impl true
    def init(opts) do
      response = Keyword.get(opts, :response, "Hello from FakeEngine!")
      {:ok, %{response: response}}
    end

    @impl true
    def handle_call(:get_state, _from, state) do
      {:reply, {:ok, %{mode: :fake, message_count: 0}}, state}
    end

    @impl true
    def handle_call({:send_message, _message}, _from, state) do
      {:reply, {:ok, state.response}, state}
    end

    def handle_call({:send_message, _message, _metadata}, _from, state) do
      {:reply, {:ok, state.response}, state}
    end
  end

  # ---------------------------------------------------------------
  # Setup
  # ---------------------------------------------------------------

  setup_all do
    table = :ets.new(:integration_test_replies, [:named_table, :public, :bag])

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
    :ets.delete_all_objects(:integration_test_replies)

    # Ensure infrastructure processes are running (idempotent, unlinked)
    Application.ensure_all_started(:phoenix_pubsub)

    start_unlinked(Phoenix.PubSub.Supervisor, name: Assistant.PubSub)
    start_unlinked(Task.Supervisor, name: Assistant.Skills.TaskSupervisor)
    start_unlinked(Elixir.Registry, keys: :unique, name: Assistant.Orchestrator.EngineRegistry)

    # DynamicSupervisor for Engine processes
    start_unlinked(DynamicSupervisor,
      strategy: :one_for_one,
      name: Assistant.Orchestrator.ConversationSupervisor
    )

    # Mox global mode for cross-process stub access (Sentinel uses MockLLMClient)
    Mox.set_mox_global(self())

    stub(MockLLMClient, :chat_completion, fn _messages, _opts ->
      {:ok,
       %{
         id: "sentinel-stub",
         model: "stub",
         content:
           Jason.encode!(%{
             reasoning: "Integration test — auto-approved.",
             decision: "approve",
             reason: "Test stub: all actions approved."
           }),
         tool_calls: [],
         finish_reason: "stop",
         usage: %{prompt_tokens: 0, completion_tokens: 0, total_tokens: 0}
       }}
    end)

    :ok
  end

  setup :verify_on_exit!

  # ---------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------

  defp start_unlinked(module, opts) do
    case module.start_link(opts) do
      {:ok, pid} -> Process.unlink(pid)
      {:error, {:already_started, _}} -> :ok
    end
  end

  defp build_message(overrides) do
    defaults = %{
      id: "msg-#{System.unique_integer([:positive])}",
      channel: :telegram,
      channel_message_id: "ch-#{System.unique_integer([:positive])}",
      space_id: "integ-#{System.unique_integer([:positive])}",
      user_id: "#{System.unique_integer([:positive])}",
      user_display_name: "Integration User",
      content: "Hello, integration test!"
    }

    struct!(Message, Map.merge(defaults, overrides))
  end

  defp await_reply_for(space_id, timeout_ms \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    Stream.repeatedly(fn ->
      case :ets.match_object(:integration_test_replies, {space_id, :_, :_, :_}) do
        [match | _] -> {:found, match}
        [] -> {:wait, nil}
      end
    end)
    |> Enum.reduce_while(nil, fn
      {:found, match}, _acc ->
        {:halt, match}

      {:wait, _}, _acc ->
        if System.monotonic_time(:millisecond) > deadline do
          all = :ets.tab2list(:integration_test_replies)
          flunk("Timed out waiting for reply to space_id #{space_id}, table: #{inspect(all)}")
        else
          Process.sleep(50)
          {:cont, nil}
        end
    end)
  end

  defp await_task_exit({_space_id, _text, _opts, pid}, timeout_ms \\ 2_000) do
    ref = Process.monitor(pid)

    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
    after
      timeout_ms ->
        Process.demonitor(ref, [:flush])
        :ok
    end
  end

  # ---------------------------------------------------------------
  # Stage 1: UserResolver resolves real DB users correctly
  # ---------------------------------------------------------------

  describe "stage 1: UserResolver integration" do
    test "resolve creates user + identity + conversation for new platform ID" do
      external_id = "#{System.unique_integer([:positive])}"

      assert {:ok, %{user_id: uid, conversation_id: cid}} =
               UserResolver.resolve(:telegram, external_id, %{display_name: "IntegUser"})

      # Verify DB state
      user = Repo.get!(User, uid)
      assert user.external_id == external_id
      assert user.channel == "telegram"
      assert user.display_name == "IntegUser"

      identity =
        Repo.one!(
          from(ui in UserIdentity,
            where: ui.user_id == ^uid and ui.channel == "telegram"
          )
        )

      assert identity.external_id == external_id

      conversation = Repo.get!(Conversation, cid)
      assert conversation.user_id == uid
      assert conversation.status == "active"
    end

    test "resolve returns existing user for pre-seeded identity" do
      {user, _identity, conversation} =
        user_with_conversation_fixture(%{
          channel: "telegram",
          external_id: "555666777"
        })

      assert {:ok, %{user_id: uid, conversation_id: cid}} =
               UserResolver.resolve(:telegram, "555666777")

      assert uid == user.id
      assert cid == conversation.id
    end
  end

  # ---------------------------------------------------------------
  # Stage 2: Dispatcher → UserResolver → Error (no Engine) → Reply
  # ---------------------------------------------------------------

  describe "stage 2: dispatch pipeline error propagation" do
    test "dispatch with invalid platform ID sends error reply directly" do
      space = "invalid-integ-#{System.unique_integer([:positive])}"

      msg =
        build_message(%{
          user_id: "not;numeric",
          space_id: space,
          channel: :telegram
        })

      assert {:ok, :dispatched} = Dispatcher.dispatch(IntegrationAdapter, msg)

      {_sid, text, _opts, _pid} = await_reply_for(space)
      assert text =~ "couldn't identify"
    end

    test "dispatch with valid user but no Engine config sends error reply" do
      # Create a real user so UserResolver succeeds
      ext_id = "#{System.unique_integer([:positive])}"
      space = "no-engine-#{System.unique_integer([:positive])}"

      {_user, _identity, _conversation} =
        user_with_conversation_fixture(%{
          channel: "telegram",
          external_id: ext_id
        })

      msg =
        build_message(%{
          user_id: ext_id,
          space_id: space,
          channel: :telegram
        })

      assert {:ok, :dispatched} = Dispatcher.dispatch(IntegrationAdapter, msg)

      # The Engine will attempt to start but the LLM loop will fail.
      # Dispatcher catches this and sends an error reply.
      reply = await_reply_for(space, 10_000)
      {_sid, text, _opts, _pid} = reply
      assert is_binary(text)
      assert text =~ "error" or text =~ "Error" or text =~ "encountered"

      await_task_exit(reply)
    end

    test "dispatch preserves thread_id through error path" do
      space = "thread-err-#{System.unique_integer([:positive])}"

      msg =
        build_message(%{
          user_id: "bad;id",
          space_id: space,
          channel: :telegram,
          thread_id: "thread-integ-123"
        })

      assert {:ok, :dispatched} = Dispatcher.dispatch(IntegrationAdapter, msg)

      {_sid, _text, opts, _pid} = await_reply_for(space)
      assert Keyword.get(opts, :thread_name) == "thread-integ-123"
    end
  end

  # ---------------------------------------------------------------
  # Stage 3: Full happy path with FakeEngine
  # ---------------------------------------------------------------

  describe "stage 3: full pipeline with FakeEngine" do
    test "dispatch → resolve → FakeEngine → reply delivers response" do
      # Create user + identity + conversation
      ext_id = "#{System.unique_integer([:positive])}"
      space = "happy-#{System.unique_integer([:positive])}"

      {user, _identity, _conversation} =
        user_with_conversation_fixture(%{
          channel: "telegram",
          external_id: ext_id
        })

      # Start a FakeEngine registered under this user's ID
      expected_response = "This is the FakeEngine response for integration test!"
      {:ok, fake_pid} = FakeEngine.start_link(user.id, response: expected_response)

      msg =
        build_message(%{
          user_id: ext_id,
          space_id: space,
          channel: :telegram,
          content: "Hello FakeEngine!"
        })

      assert {:ok, :dispatched} = Dispatcher.dispatch(IntegrationAdapter, msg)

      reply = await_reply_for(space, 5_000)
      {_sid, text, _opts, _pid} = reply

      assert text == expected_response

      await_task_exit(reply)

      # Cleanup
      GenServer.stop(fake_pid, :normal, 5_000)
    end

    test "FakeEngine reply includes correct space_id from origin" do
      ext_id = "#{System.unique_integer([:positive])}"
      space = "origin-#{System.unique_integer([:positive])}"

      {user, _identity, _conversation} =
        user_with_conversation_fixture(%{
          channel: "telegram",
          external_id: ext_id
        })

      {:ok, fake_pid} = FakeEngine.start_link(user.id, response: "origin test reply")

      msg =
        build_message(%{
          user_id: ext_id,
          space_id: space,
          channel: :telegram
        })

      assert {:ok, :dispatched} = Dispatcher.dispatch(IntegrationAdapter, msg)

      {reply_sid, text, _opts, _pid} = await_reply_for(space, 5_000)
      assert reply_sid == space
      assert text == "origin test reply"

      GenServer.stop(fake_pid, :normal, 5_000)
    end

    test "FakeEngine reply preserves thread_id in successful path" do
      ext_id = "#{System.unique_integer([:positive])}"
      space = "thread-ok-#{System.unique_integer([:positive])}"

      {user, _identity, _conversation} =
        user_with_conversation_fixture(%{
          channel: "telegram",
          external_id: ext_id
        })

      {:ok, fake_pid} = FakeEngine.start_link(user.id, response: "threaded response")

      msg =
        build_message(%{
          user_id: ext_id,
          space_id: space,
          channel: :telegram,
          thread_id: "thread-success-456"
        })

      assert {:ok, :dispatched} = Dispatcher.dispatch(IntegrationAdapter, msg)

      {_sid, _text, opts, _pid} = await_reply_for(space, 5_000)
      # ReplyRouter should include thread_name in opts
      assert Keyword.get(opts, :thread_name) == "thread-success-456"

      GenServer.stop(fake_pid, :normal, 5_000)
    end
  end

  # ---------------------------------------------------------------
  # Stage 4: Multi-user concurrent dispatch with FakeEngines
  # ---------------------------------------------------------------

  describe "stage 4: concurrent multi-user dispatch" do
    test "multiple users dispatching concurrently each get their own reply" do
      user_count = 5

      # Create N users, each with a FakeEngine
      user_data =
        for i <- 1..user_count do
          ext_id = "#{System.unique_integer([:positive])}"
          space = "multi-user-#{i}-#{System.unique_integer([:positive])}"
          response = "Response for user #{i}"

          {user, _identity, _conversation} =
            user_with_conversation_fixture(%{
              channel: "telegram",
              external_id: ext_id
            })

          {:ok, fake_pid} = FakeEngine.start_link(user.id, response: response)

          %{
            ext_id: ext_id,
            space: space,
            expected_response: response,
            fake_pid: fake_pid
          }
        end

      # Dispatch all concurrently
      tasks =
        Enum.map(user_data, fn ud ->
          msg =
            build_message(%{
              user_id: ud.ext_id,
              space_id: ud.space,
              channel: :telegram,
              content: "Hello from user with ext_id #{ud.ext_id}"
            })

          Task.async(fn ->
            Dispatcher.dispatch(IntegrationAdapter, msg)
          end)
        end)

      results = Task.await_many(tasks, 10_000)
      assert Enum.all?(results, &(&1 == {:ok, :dispatched}))

      # Verify each user got their specific reply
      for ud <- user_data do
        {_sid, text, _opts, _pid} = await_reply_for(ud.space, 5_000)
        assert text == ud.expected_response
      end

      # Cleanup
      for ud <- user_data do
        GenServer.stop(ud.fake_pid, :normal, 5_000)
      end
    end
  end

  # ---------------------------------------------------------------
  # Stage 5: Error resilience — various failure modes
  # ---------------------------------------------------------------

  describe "stage 5: error resilience" do
    test "dispatch to unknown channel type still delivers via adapter" do
      space = "unknown-ch-#{System.unique_integer([:positive])}"

      msg =
        build_message(%{
          channel: :unknown_channel,
          user_id: "anything-goes-#{System.unique_integer([:positive])}",
          space_id: space
        })

      # Unknown channels pass platform ID validation (no pattern to match against)
      # UserResolver will auto-create the user, then Engine will fail
      assert {:ok, :dispatched} = Dispatcher.dispatch(IntegrationAdapter, msg)

      reply = await_reply_for(space, 10_000)
      {_sid, text, _opts, _pid} = reply
      assert is_binary(text)

      await_task_exit(reply)
    end

    test "dispatch never drops messages — always sends some reply" do
      # Test with various edge-case inputs
      test_cases = [
        %{user_id: "bad;id", channel: :telegram},
        %{user_id: "", channel: :telegram},
        %{user_id: "123", channel: :slack},
        %{user_id: "spaces/no", channel: :google_chat}
      ]

      for tc <- test_cases do
        space = "never-drop-#{System.unique_integer([:positive])}"

        msg = build_message(Map.merge(tc, %{space_id: space}))

        assert {:ok, :dispatched} = Dispatcher.dispatch(IntegrationAdapter, msg)

        {_sid, text, _opts, _pid} = await_reply_for(space, 5_000)

        assert is_binary(text),
               "Expected binary reply for #{inspect(tc)}, got: #{inspect(text)}"
      end
    end
  end
end
