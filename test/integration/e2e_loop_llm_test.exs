# test/integration/e2e_loop_llm_test.exs — Real-LLM end-to-end tests for the Engine loop.
#
# Exercises the FULL Engine.send_message → LoopRunner → LLMRouter → OpenRouter
# pipeline with REAL LLM API calls. Verifies that the Engine can drive a
# multi-iteration orchestration loop, select appropriate tools, and produce
# coherent responses.
#
# These tests use real OpenRouter API calls (requires OPENROUTER_API_KEY) with
# the actual Skills.Registry and PromptLoader. External service integrations
# (Gmail, Calendar, Drive) are NOT mocked here — the Engine uses
# Integrations.Registry.default_integrations() which requires real tokens.
# Since test users don't have Google OAuth tokens, sub-agent dispatches
# touching Google services will return "not configured" errors — this is
# tested explicitly in the error resilience section.
#
# Assertions target STRUCTURE and BEHAVIOR, not exact LLM text output:
#   - Did we get a text response?
#   - Did the Engine iterate the expected number of times?
#   - Does get_state reflect the correct internal state?
#   - Did the response reference expected topics?
#
# Related files:
#   - test/assistant/orchestrator/e2e_loop_test.exs (Bypass-based E2E tests)
#   - test/integration/tool_use_llm_test.exs (real-LLM tool selection tests)
#   - lib/assistant/orchestrator/engine.ex (Engine GenServer)
#   - lib/assistant/orchestrator/loop_runner.ex (LLM loop logic)

defmodule Assistant.Integration.E2ELoopLLMTest do
  use Assistant.DataCase, async: false
  # async: false — Engine uses named registries, ConfigLoader uses ETS

  import Mox
  import Assistant.Integration.TestLogger

  @moduletag :integration
  @moduletag timeout: 180_000

  alias Assistant.Orchestrator.Engine
  alias Assistant.Schemas.{Conversation, User}

  require Logger

  setup :verify_on_exit!

  setup do
    # Trap exits so Engine crashes don't kill the test process
    Process.flag(:trap_exit, true)

    # --- API Key Check ---
    api_key = System.get_env("OPENROUTER_API_KEY")

    if is_nil(api_key) or api_key == "" do
      flunk("OPENROUTER_API_KEY not set — required for real-LLM integration tests")
    end

    # Save original config value so we can restore it in on_exit
    # (deleting the key causes TurnClassifier background Tasks to crash)
    original_key = Application.get_env(:assistant, :openrouter_api_key)

    # Ensure the real API key is available to OpenRouter client
    Application.put_env(:assistant, :openrouter_api_key, api_key)

    # --- Infrastructure setup (idempotent, unlinked) ---
    Application.ensure_all_started(:phoenix_pubsub)

    start_unlinked(Phoenix.PubSub.Supervisor, name: Assistant.PubSub)
    start_unlinked(Task.Supervisor, name: Assistant.Skills.TaskSupervisor)
    start_unlinked(Elixir.Registry, keys: :unique, name: Assistant.Orchestrator.EngineRegistry)
    start_unlinked(Elixir.Registry, keys: :unique, name: Assistant.SubAgent.Registry)

    # Real Skills.Registry (loads actual skill definitions from priv/skills)
    skills_dir = Path.join(File.cwd!(), "priv/skills")

    if :ets.whereis(:assistant_skills) == :undefined and File.dir?(skills_dir) do
      start_unlinked(Assistant.Skills.Registry, skills_dir: skills_dir)
    end

    # Real PromptLoader (loads actual prompt templates from priv/config/prompts)
    prompts_dir = Path.join(File.cwd!(), "priv/config/prompts")

    if :ets.whereis(:assistant_prompts) == :undefined and File.dir?(prompts_dir) do
      start_unlinked(Assistant.Config.PromptLoader, dir: prompts_dir)
    end

    # Config.Loader (ETS-backed GenServer for model/limits config)
    ensure_config_loader_started()

    # MockCallRecorder for tracking tool invocations
    Assistant.Integration.MockCallRecorder.clear()

    # Set Mox to global mode so dynamically spawned sub-agent Task processes
    # can access the MockLLMClient stub. The Sentinel uses @llm_client
    # (MockLLMClient in test env) for security gate checks inside sub-agent
    # Task processes that are not in the test process's caller chain.
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

    on_exit(fn ->
      # Restore original API key value (not delete!) to prevent
      # TurnClassifier background Tasks from crashing on key lookup
      Application.put_env(:assistant, :openrouter_api_key, original_key)
    end)

    %{api_key: api_key}
  end

  # ---------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------

  defp create_user_and_conversation do
    user =
      %User{}
      |> User.changeset(%{
        external_id: "e2e-llm-#{System.unique_integer([:positive])}",
        channel: "test"
      })
      |> Repo.insert!()

    {:ok, conversation} =
      %Conversation{}
      |> Conversation.changeset(%{channel: "test", user_id: user.id})
      |> Repo.insert()

    {user, conversation}
  end

  defp safe_stop(pid) do
    if Process.alive?(pid) do
      try do
        GenServer.stop(pid, :normal, 5_000)
      catch
        :exit, _ -> :ok
      end
    end
  end

  defp start_unlinked(module, opts) do
    case module.start_link(opts) do
      {:ok, pid} -> Process.unlink(pid)
      {:error, {:already_started, _}} -> :ok
    end
  end

  # Wraps Engine.send_message with verbose request/response logging.
  defp engine_send(conversation_id, message, label \\ "e2e") do
    log_request(label, %{
      messages: [%{role: "user", content: message}],
      model: "(via Engine pipeline)"
    })

    {elapsed, result} =
      timed(fn -> Engine.send_message(conversation_id, message) end)

    case result do
      {:ok, response} ->
        log_response(label, {:ok, %{content: response}})
        log_pass(label, elapsed)

      {:error, reason} ->
        log_response(label, {:error, reason})
        log_fail(label, reason)
    end

    result
  end

  defp ensure_config_loader_started do
    if :ets.whereis(:assistant_config) != :undefined do
      :ok
    else
      tmp_dir = System.tmp_dir!()

      config_path =
        Path.join(tmp_dir, "test_config_e2e_llm_#{System.unique_integer([:positive])}.yaml")

      File.write!(config_path, """
      models:
        default: "openai/gpt-5.2"
        roster:
          - "openai/gpt-5.2"
      limits:
        max_context_tokens: 128000
        max_output_tokens: 4096
        orchestrator_budget: 0.8
        context_budget: 0.15
        user_message_budget: 0.05
      http:
        max_retries: 1
        base_timeout: 60000
        max_timeout: 120000
      """)

      start_unlinked(Assistant.Config.Loader, path: config_path)
    end
  end

  # ---------------------------------------------------------------
  # 1. Simple conversation — text response, no tools
  # ---------------------------------------------------------------

  describe "simple conversation with real LLM" do
    @tag :integration
    @tag timeout: 120_000
    test "Engine returns a text response to a simple greeting" do
      {user, conversation} = create_user_and_conversation()

      {:ok, pid} = Engine.start_link(conversation.id, user_id: user.id, channel: "test")

      result = engine_send(conversation.id, "Hello! What is 2 + 2?", "simple_greeting")

      assert {:ok, response} = result
      assert is_binary(response)
      assert String.length(response) > 0

      # The response should mention "4" somewhere
      assert response =~ "4"

      # Engine state should show 1 iteration (direct text response)
      {:ok, state} = Engine.get_state(conversation.id)
      assert state.iteration_count >= 1
      assert state.message_count >= 2  # at least user + assistant

      safe_stop(pid)
    end

    @tag :integration
    @tag timeout: 120_000
    test "Engine returns a substantive response to a knowledge question" do
      {user, conversation} = create_user_and_conversation()

      {:ok, pid} = Engine.start_link(conversation.id, user_id: user.id, channel: "test")

      result =
        engine_send(
          conversation.id,
          "In one sentence, what is the capital of France?",
          "knowledge_question"
        )

      assert {:ok, response} = result
      assert is_binary(response)
      assert String.length(response) > 5

      # Should mention Paris
      assert response =~ ~r/[Pp]aris/

      safe_stop(pid)
    end
  end

  # ---------------------------------------------------------------
  # 2. Skill discovery via get_skill
  # ---------------------------------------------------------------

  describe "skill discovery with real LLM" do
    @tag :integration
    @tag timeout: 120_000
    test "Engine uses get_skill when asked about capabilities" do
      {user, conversation} = create_user_and_conversation()

      {:ok, pid} = Engine.start_link(conversation.id, user_id: user.id, channel: "test")

      result =
        engine_send(
          conversation.id,
          "What email skills do you have available? Use your tools to find out.",
          "skill_discovery_email"
        )

      assert {:ok, response} = result
      assert is_binary(response)
      assert String.length(response) > 10

      # Engine should have iterated more than once (get_skill call + final response)
      {:ok, state} = Engine.get_state(conversation.id)
      assert state.iteration_count >= 2

      # Response should mention email-related capabilities
      assert response =~ ~r/email|search|send|read|list|draft/i

      safe_stop(pid)
    end

    @tag :integration
    @tag timeout: 120_000
    test "Engine discovers all skill domains when asked broadly" do
      {user, conversation} = create_user_and_conversation()

      {:ok, pid} = Engine.start_link(conversation.id, user_id: user.id, channel: "test")

      result =
        engine_send(
          conversation.id,
          "What can you do? List all your skill domains. Use your tools to check.",
          "skill_discovery_all"
        )

      assert {:ok, response} = result
      assert is_binary(response)

      # Should have used get_skill tool (iteration_count > 1)
      {:ok, state} = Engine.get_state(conversation.id)
      assert state.iteration_count >= 2

      # Response should mention multiple domains
      response_lower = String.downcase(response)
      domain_hits =
        ["email", "calendar", "file", "task", "memory", "workflow"]
        |> Enum.count(fn domain -> String.contains?(response_lower, domain) end)

      # Should mention at least 3 of the 6+ domains
      assert domain_hits >= 3,
             "Expected at least 3 skill domains mentioned, got #{domain_hits}. Response: #{response}"

      safe_stop(pid)
    end
  end

  # ---------------------------------------------------------------
  # 3. Multi-step tool chain — get_skill then dispatch_agent
  # ---------------------------------------------------------------

  describe "multi-step tool chain with real LLM" do
    @tag :integration
    @tag timeout: 120_000
    test "Engine iterates multiple times for a tool-requiring request" do
      {user, conversation} = create_user_and_conversation()

      {:ok, pid} = Engine.start_link(conversation.id, user_id: user.id, channel: "test")

      # Ask something that requires discovering skills first, then acting
      result =
        engine_send(
          conversation.id,
          "First check what email skills are available, then tell me about them. Use your get_skill tool.",
          "chain_email_skills"
        )

      assert {:ok, response} = result
      assert is_binary(response)

      {:ok, state} = Engine.get_state(conversation.id)

      # Should have at least 2 iterations: get_skill + final text
      assert state.iteration_count >= 2

      # Response should describe email skills
      assert response =~ ~r/email|search|send|read|list|draft/i

      safe_stop(pid)
    end

    @tag :integration
    @tag timeout: 120_000
    test "Engine handles get_skill for multiple domains in sequence" do
      {user, conversation} = create_user_and_conversation()

      {:ok, pid} = Engine.start_link(conversation.id, user_id: user.id, channel: "test")

      result =
        engine_send(
          conversation.id,
          "Look up what skills are available in both the email domain and the calendar domain. Use get_skill for each.",
          "chain_multi_domain"
        )

      assert {:ok, response} = result
      assert is_binary(response)

      {:ok, state} = Engine.get_state(conversation.id)

      # Should have multiple iterations (at least one get_skill + response)
      assert state.iteration_count >= 2

      # Response should mention both domains
      response_lower = String.downcase(response)
      assert String.contains?(response_lower, "email") or String.contains?(response_lower, "mail")
      assert String.contains?(response_lower, "calendar") or String.contains?(response_lower, "event")

      safe_stop(pid)
    end
  end

  # ---------------------------------------------------------------
  # 4. Context preservation across turns
  # ---------------------------------------------------------------

  describe "context preservation with real LLM" do
    @tag :integration
    @tag timeout: 120_000
    test "Engine preserves context across multiple turns" do
      {user, conversation} = create_user_and_conversation()

      {:ok, pid} = Engine.start_link(conversation.id, user_id: user.id, channel: "test")

      # Turn 1: Establish context
      {:ok, _} =
        engine_send(
          conversation.id,
          "Remember this: my favorite color is turquoise.",
          "context_turn1"
        )

      # Turn 2: Reference prior context
      {:ok, response2} =
        engine_send(
          conversation.id,
          "What is my favorite color? Answer in one word.",
          "context_turn2"
        )

      assert is_binary(response2)
      assert response2 =~ ~r/[Tt]urquoise/

      # State should show growing message history
      {:ok, state} = Engine.get_state(conversation.id)
      # At minimum: user1 + assistant1 + user2 + assistant2 = 4
      assert state.message_count >= 4

      safe_stop(pid)
    end

    @tag :integration
    @tag timeout: 120_000
    test "Engine maintains conversation thread across three turns" do
      {user, conversation} = create_user_and_conversation()

      {:ok, pid} = Engine.start_link(conversation.id, user_id: user.id, channel: "test")

      # Turn 1
      {:ok, _} =
        engine_send(conversation.id, "My name is Zephyr.", "thread_turn1")

      # Turn 2
      {:ok, _} =
        engine_send(conversation.id, "I live in a lighthouse.", "thread_turn2")

      # Turn 3: Reference both prior turns
      {:ok, response3} =
        engine_send(
          conversation.id,
          "What is my name and where do I live? Answer briefly.",
          "thread_turn3"
        )

      assert is_binary(response3)
      assert response3 =~ ~r/[Zz]ephyr/
      assert response3 =~ ~r/[Ll]ighthouse/

      {:ok, state} = Engine.get_state(conversation.id)
      # 3 turns * 2 messages = 6 minimum
      assert state.message_count >= 6

      safe_stop(pid)
    end
  end

  # ---------------------------------------------------------------
  # 5. Error resilience — graceful handling of tool errors
  # ---------------------------------------------------------------

  describe "error resilience with real LLM" do
    @tag :integration
    @tag timeout: 120_000
    test "Engine produces a response even when dispatched agent would fail" do
      {user, conversation} = create_user_and_conversation()

      {:ok, pid} = Engine.start_link(conversation.id, user_id: user.id, channel: "test")

      # Ask the LLM to search emails — dispatch_agent will fail because
      # no Google OAuth token exists for this test user. The Engine should
      # handle the error gracefully and still produce a text response.
      result =
        engine_send(
          conversation.id,
          "Search my emails for messages from alice@example.com about the weekly report.",
          "error_agent_fail"
        )

      # We should still get SOME response (either error message or graceful fallback)
      case result do
        {:ok, response} ->
          assert is_binary(response)
          assert String.length(response) > 0

        {:error, _reason} ->
          # An error is also acceptable — the Engine didn't crash
          :ok
      end

      # Most importantly: the Engine is still alive and responsive
      assert {:ok, _state} = Engine.get_state(conversation.id)

      safe_stop(pid)
    end

    @tag :integration
    @tag timeout: 120_000
    test "Engine survives error and handles next message" do
      {user, conversation} = create_user_and_conversation()

      {:ok, pid} = Engine.start_link(conversation.id, user_id: user.id, channel: "test")

      # First message: something that might trigger tool errors
      _result1 =
        engine_send(
          conversation.id,
          "Send an email to nobody@example.com saying hello",
          "error_survive_msg1"
        )

      # Engine should still be alive
      assert Process.alive?(pid)

      # Second message: simple question that shouldn't need tools
      result2 =
        engine_send(conversation.id, "What is 3 + 7?", "error_survive_msg2")

      assert {:ok, response2} = result2
      assert is_binary(response2)
      assert response2 =~ "10"

      safe_stop(pid)
    end
  end

  # ---------------------------------------------------------------
  # 6. Engine mode verification
  # ---------------------------------------------------------------

  describe "engine modes with real LLM" do
    @tag :integration
    @tag timeout: 120_000
    test "Engine works in single_loop mode" do
      {user, conversation} = create_user_and_conversation()

      {:ok, pid} =
        Engine.start_link(conversation.id,
          user_id: user.id,
          channel: "test",
          mode: :single_loop
        )

      {:ok, state} = Engine.get_state(conversation.id)
      assert state.mode == :single_loop

      result = engine_send(conversation.id, "Say hello in exactly one word.", "single_loop")

      assert {:ok, response} = result
      assert is_binary(response)
      assert String.length(response) > 0

      safe_stop(pid)
    end
  end

  # ---------------------------------------------------------------
  # 7. Token usage tracking
  # ---------------------------------------------------------------

  describe "token usage tracking with real LLM" do
    @tag :integration
    @tag timeout: 120_000
    test "Engine accumulates real token usage" do
      {user, conversation} = create_user_and_conversation()

      {:ok, pid} = Engine.start_link(conversation.id, user_id: user.id, channel: "test")

      {:ok, _} = engine_send(conversation.id, "Hello, how are you?", "token_tracking")

      {:ok, state} = Engine.get_state(conversation.id)

      # Real LLM calls should produce non-zero token usage
      assert state.total_usage.prompt_tokens > 0
      assert state.total_usage.completion_tokens > 0

      safe_stop(pid)
    end
  end
end
