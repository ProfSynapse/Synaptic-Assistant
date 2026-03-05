# test/integration/approval_gate_llm_test.exs — Real-LLM end-to-end tests for the approval gate.
#
# Exercises the FULL production approval gate flow with real LLM API calls:
#   Turn 1: User request -> Engine -> Orchestrator LLM -> dispatch_agent
#           -> Sub-agent LLM -> use_skill (email.send) -> approval gate fires
#           -> Sub-agent pauses -> Orchestrator sees [APPROVAL_REQUIRED]
#           -> Asks user for approval
#   Turn 2: User says "Approve" -> Engine -> Orchestrator LLM
#           -> send_agent_update(approved: true) -> Sub-agent resumes
#           -> Skill executes (fails: no Gmail token) -> Orchestrator reports result
#
# These tests are 1:1 production emulation. The ONLY mock is the Sentinel
# (MockLLMRouter) which auto-approves security checks. All orchestrator and
# sub-agent LLM calls go through OpenRouter with real API keys.
#
# Related files:
#   - test/integration/e2e_loop_llm_test.exs (other real-LLM E2E tests)
#   - test/assistant/skills/approval_gate_test.exs (unit tests: gate, resume, deny)
#   - lib/assistant/orchestrator/sub_agent.ex (gate logic)
#   - lib/assistant/orchestrator/tools/send_agent_update.ex (resume tool)

defmodule Assistant.Integration.ApprovalGateLLMTest do
  use Assistant.DataCase, async: false
  # async: false — Engine uses named registries, ETS tables

  import Mox
  import Assistant.Integration.TestLogger

  @moduletag :integration
  @moduletag timeout: 600_000

  alias Assistant.Orchestrator.Engine
  alias Assistant.Schemas.{Conversation, User}

  require Logger

  setup :verify_on_exit!

  setup do
    Process.flag(:trap_exit, true)

    api_key = System.get_env("OPENROUTER_API_KEY")

    if is_nil(api_key) or api_key == "" do
      flunk("OPENROUTER_API_KEY not set — required for real-LLM integration tests")
    end

    original_key = Application.get_env(:assistant, :openrouter_api_key)
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

    # Real PromptLoader
    prompts_dir = Path.join(File.cwd!(), "priv/config/prompts")

    if :ets.whereis(:assistant_prompts) == :undefined and File.dir?(prompts_dir) do
      start_unlinked(Assistant.Config.PromptLoader, dir: prompts_dir)
    end

    ensure_config_loader_started()

    # Stub Sentinel (MockLLMRouter) — auto-approve all security gate checks.
    # The Sentinel runs in sub-agent Task processes, so we need global mode.
    Mox.set_mox_global(self())

    stub(MockLLMRouter, :chat_completion, fn _messages, _opts, _user_id ->
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
        external_id: "approval-gate-#{System.unique_integer([:positive])}",
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

  defp engine_send(user_id, message, label) do
    log_request(label, %{
      messages: [%{role: "user", content: message}],
      model: "(via Engine pipeline)"
    })

    {elapsed, result} =
      timed(fn -> Engine.send_message(user_id, message) end)

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

  # OpenRouter model config — same models as e2e_loop_llm_test
  @test_models [
    %{
      id: "openai/gpt-5.2",
      tier: :primary,
      description: "GPT-5.2 — integration test model",
      use_cases: [:orchestrator, :sub_agent],
      supports_tools: true,
      max_context_tokens: 400_000,
      cost_tier: :high
    },
    %{
      id: "openai/gpt-5-mini",
      tier: :fast,
      description: "GPT-5 Mini — fast fallback",
      use_cases: [:sub_agent, :compaction, :sentinel],
      supports_tools: true,
      max_context_tokens: 400_000,
      cost_tier: :low
    }
  ]

  @test_defaults %{
    orchestrator: :primary,
    sub_agent: :primary,
    compaction: :fast,
    sentinel: :fast
  }

  defp ensure_config_loader_started do
    if :ets.whereis(:assistant_config) != :undefined do
      :ets.insert(:assistant_config, {:models, @test_models})
      :ets.insert(:assistant_config, {:defaults, @test_defaults})
      :ok
    else
      tmp_dir = System.tmp_dir!()

      config_path =
        Path.join(tmp_dir, "test_config_approval_#{System.unique_integer([:positive])}.yaml")

      File.write!(config_path, """
      defaults:
        orchestrator: primary
        sub_agent: primary
        compaction: fast
        sentinel: fast

      models:
        - id: "openai/gpt-5.2"
          tier: primary
          description: "GPT-5.2 — integration test"
          use_cases:
            - orchestrator
            - sub_agent
          supports_tools: true
          max_context_tokens: 400000
          cost_tier: high
        - id: "openai/gpt-5-mini"
          tier: fast
          description: "GPT-5 Mini — fast fallback"
          use_cases:
            - sub_agent
            - compaction
            - sentinel
          supports_tools: true
          max_context_tokens: 400000
          cost_tier: low

      http:
        max_retries: 1
        base_backoff_ms: 1000
        max_backoff_ms: 5000
        request_timeout_ms: 120000
        streaming_timeout_ms: 300000

      limits:
        context_utilization_target: 0.85
        compaction_trigger_threshold: 0.75
        response_reserve_tokens: 4096
        orchestrator_turn_limit: 100
        sub_agent_turn_limit: 30
        cache_ttl_seconds: 3600
        orchestrator_cache_breakpoints: 4
        sub_agent_cache_breakpoints: 1
      """)

      start_unlinked(Assistant.Config.Loader, path: config_path)
    end
  end

  # ---------------------------------------------------------------
  # 1. Full approval gate flow: email send
  #
  # Emulates the complete production flow:
  #   Turn 1: User asks to send email -> orchestrator dispatches sub-agent
  #           -> sub-agent calls email.send -> gate fires -> orchestrator
  #           presents approval request to user
  #   Turn 2: User says "Yes, send it" -> orchestrator resumes sub-agent
  #           with approved=true -> sub-agent executes skill (fails: no Gmail)
  #           -> orchestrator reports the result
  #
  # This is 1:1 what happens in production. The only difference is
  # the Sentinel is stubbed (MockLLMClient) since we don't need
  # security gate LLM calls for testing the approval flow.
  # ---------------------------------------------------------------

  describe "full approval gate flow: email send" do
    @tag :integration
    @tag timeout: 180_000
    test "turn 1: orchestrator presents email details for approval, turn 2: user approves" do
      {user, conversation} = create_user_and_conversation()

      {:ok, pid} = Engine.start_link(user.id, conversation_id: conversation.id, channel: "test")

      # --- Turn 1: User asks to send an email ---
      result =
        engine_send(
          user.id,
          "Send an email to bob@example.com with subject 'Weekly Report' and body " <>
            "'Hi Bob, here are the action items from our meeting. Please review and confirm.'",
          "email_gate_turn1"
        )

      assert {:ok, turn1_response} = result
      assert is_binary(turn1_response)
      assert String.length(turn1_response) > 10

      # The orchestrator should ask for approval and include email details.
      # Whether it dispatched a sub-agent (saw [APPROVAL_REQUIRED]) or
      # recognized the approval requirement from the prompt, the user-facing
      # result should be the same: present details, ask for confirmation.
      turn1_lower = String.downcase(turn1_response)

      approval_indicators =
        ["approv", "confirm", "proceed", "shall i", "would you like",
         "go ahead", "authorize", "review", "send"]

      assert Enum.any?(approval_indicators, &String.contains?(turn1_lower, &1)),
             "Turn 1: Expected approval prompt. Got: #{turn1_response}"

      has_email_details =
        String.contains?(turn1_lower, "bob@example.com") or
          String.contains?(turn1_lower, "weekly report") or
          String.contains?(turn1_lower, "action items")

      assert has_email_details,
             "Turn 1: Expected email details in response. Got: #{turn1_response}"

      # Verify the engine has dispatched agents (if the sub-agent path was taken)
      {:ok, engine_state} = Engine.get_state(user.id)
      dispatched_ids = engine_state.dispatched_agents

      if dispatched_ids != [] do
        Logger.info("Turn 1 dispatched agents: #{inspect(dispatched_ids)}")
      else
        Logger.info("Turn 1: Orchestrator handled approval directly (no sub-agent dispatch)")
      end

      # --- Turn 2: User approves ---
      result2 =
        engine_send(
          user.id,
          "Yes, send it.",
          "email_gate_turn2"
        )

      assert {:ok, turn2_response} = result2
      assert is_binary(turn2_response)

      # After approval, the orchestrator should either:
      # a) Resume the paused sub-agent (send_agent_update approved=true)
      #    -> skill executes -> fails (no Gmail token) -> reports error
      # b) Dispatch a new sub-agent -> same gate/execution flow
      # c) Report that Gmail is not connected (if it realizes no token)
      #
      # Any of these is valid production behavior. The key assertion is
      # that Turn 2 does NOT ask for approval again (it should act on it).
      turn2_lower = String.downcase(turn2_response)

      # Should NOT re-ask for approval (that would mean Turn 1 approval was lost)
      re_approval_phrases = ["approve this action", "\\[approval_required\\]"]

      has_re_approval =
        Enum.any?(re_approval_phrases, fn phrase ->
          Regex.match?(~r/#{phrase}/i, turn2_lower)
        end)

      refute has_re_approval,
             "Turn 2: Should not re-ask for approval after user said yes. Got: #{turn2_response}"

      assert Process.alive?(pid)
      safe_stop(pid)
    end
  end

  # ---------------------------------------------------------------
  # 2. Full approval gate flow: user denies
  #
  # Turn 1: Same as above — orchestrator presents approval request
  # Turn 2: User says "No, cancel" -> orchestrator should acknowledge
  #         cancellation, NOT execute the skill
  # ---------------------------------------------------------------

  describe "full approval gate flow: user denies" do
    @tag :integration
    @tag timeout: 180_000
    test "turn 1: approval prompt, turn 2: user denies and orchestrator cancels" do
      {user, conversation} = create_user_and_conversation()

      {:ok, pid} = Engine.start_link(user.id, conversation_id: conversation.id, channel: "test")

      # --- Turn 1: User asks to send an email ---
      result =
        engine_send(
          user.id,
          "Send an email to alice@example.com with subject 'Contract Draft' and body " <>
            "'Please find attached the contract draft for your review.'",
          "deny_gate_turn1"
        )

      assert {:ok, turn1_response} = result
      turn1_lower = String.downcase(turn1_response)

      # Should present approval prompt with details
      has_approval =
        Enum.any?(
          ["approv", "confirm", "proceed", "shall i", "would you like",
           "go ahead", "send", "review"],
          &String.contains?(turn1_lower, &1)
        )

      assert has_approval,
             "Turn 1: Expected approval prompt. Got: #{turn1_response}"

      # --- Turn 2: User denies ---
      result2 =
        engine_send(
          user.id,
          "No, don't send that. Cancel it.",
          "deny_gate_turn2"
        )

      assert {:ok, turn2_response} = result2
      turn2_lower = String.downcase(turn2_response)

      # The orchestrator should acknowledge the cancellation
      cancellation_indicators =
        ["cancel", "won't send", "not send", "understood", "okay",
         "noted", "acknowledged", "didn't send", "haven't sent",
         "will not", "stopped", "discarded"]

      has_cancellation =
        Enum.any?(cancellation_indicators, &String.contains?(turn2_lower, &1))

      assert has_cancellation,
             "Turn 2: Expected cancellation acknowledgment. Got: #{turn2_response}"

      assert Process.alive?(pid)
      safe_stop(pid)
    end
  end

  # ---------------------------------------------------------------
  # 3. Full approval gate flow: user requests modification
  #
  # Turn 1: Orchestrator presents approval request
  # Turn 2: User asks for a change (e.g., add CC)
  # Turn 3: Orchestrator should present updated version for approval
  # ---------------------------------------------------------------

  describe "full approval gate flow: user modifies" do
    @tag :integration
    @tag timeout: 180_000
    test "turn 1: approval prompt, turn 2: user requests change, turn 3: updated approval" do
      {user, conversation} = create_user_and_conversation()

      {:ok, pid} = Engine.start_link(user.id, conversation_id: conversation.id, channel: "test")

      # --- Turn 1: User asks to send an email ---
      result =
        engine_send(
          user.id,
          "Send an email to charlie@example.com with subject 'Project Update' and body " <>
            "'The project is on track for the Q2 deadline.'",
          "modify_gate_turn1"
        )

      assert {:ok, turn1_response} = result
      turn1_lower = String.downcase(turn1_response)

      has_approval =
        Enum.any?(
          ["approv", "confirm", "proceed", "shall i", "would you like",
           "go ahead", "send", "review"],
          &String.contains?(turn1_lower, &1)
        )

      assert has_approval,
             "Turn 1: Expected approval prompt. Got: #{turn1_response}"

      # --- Turn 2: User requests a modification ---
      result2 =
        engine_send(
          user.id,
          "Actually, add CC dana@example.com and change the subject to 'Q2 Project Update'.",
          "modify_gate_turn2"
        )

      assert {:ok, turn2_response} = result2
      turn2_lower = String.downcase(turn2_response)

      # The orchestrator should acknowledge the changes and either:
      # a) Present updated email for approval (ideal)
      # b) Acknowledge and ask for confirmation with new details
      modification_indicators =
        ["dana@example.com", "q2 project update", "cc", "updated",
         "changed", "modified", "revised", "new version",
         "approv", "confirm", "proceed", "shall i", "send"]

      has_modification_response =
        Enum.any?(modification_indicators, &String.contains?(turn2_lower, &1))

      assert has_modification_response,
             "Turn 2: Expected modification acknowledgment or updated approval. Got: #{turn2_response}"

      assert Process.alive?(pid)
      safe_stop(pid)
    end
  end

  # ---------------------------------------------------------------
  # 4. Non-gated skill: no approval prompt (control test)
  #
  # Verifies that skills WITHOUT requires_approval: true do NOT
  # trigger any approval dialog. This is the control case.
  # ---------------------------------------------------------------

  describe "non-gated skill: no approval prompt" do
    @tag :integration
    @tag timeout: 120_000
    test "email search (read-only) executes without approval gate" do
      {user, conversation} = create_user_and_conversation()

      {:ok, pid} = Engine.start_link(user.id, conversation_id: conversation.id, channel: "test")

      result =
        engine_send(
          user.id,
          "Search my emails for messages from alice@example.com about the weekly report.",
          "no_gate_search"
        )

      # Should get a response that does NOT ask for approval.
      # It will likely fail because no Gmail token, but it should NOT
      # present an approval dialog.
      case result do
        {:ok, response} ->
          response_lower = String.downcase(response)

          # Should NOT contain approval-gate-specific language
          approval_phrases = ["requires.*approval", "approve this action",
                              "\\[approval_required\\]"]

          has_approval_gate =
            Enum.any?(approval_phrases, fn phrase ->
              Regex.match?(~r/#{phrase}/i, response_lower)
            end)

          refute has_approval_gate,
                 "Read-only skill should NOT trigger approval gate. Got: #{response}"

        {:error, _reason} ->
          # An error is acceptable (no Gmail token) — just verify no crash
          :ok
      end

      assert Process.alive?(pid)
      safe_stop(pid)
    end
  end
end
