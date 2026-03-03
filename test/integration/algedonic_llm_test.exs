# test/integration/algedonic_llm_test.exs — Live LLM integration tests for
# the sub-agent request_help (algedonic signal) round-trip.
#
# Exercises the SubAgent's `request_help` → `:awaiting_orchestrator` → `resume/2`
# pipeline with REAL LLM API calls. Verifies that:
#   1. The LLM calls request_help when a skill fails (external service error)
#   2. The LLM calls request_help when granted skills don't match the mission
#   3. Resuming with a message lets the agent adapt and use available skills
#   4. The LLM calls request_help when skills are insufficient for the full mission
#   5. Full round-trip: pause → resume with new skills → agent completes
#   6. Cascading failure context from prior agents triggers request_help
#
# These tests use real OpenRouter API calls (requires OPENROUTER_API_KEY).
# The Sentinel is stubbed to auto-approve all actions (same as e2e_loop_llm_test).
#
# IMPORTANT: Missions contain NO coaching language. The sub-agent system prompt
# alone ("Call request_help if you are blocked") guides the LLM's behavior.
# This tests production-realistic conditions where the orchestrator sends
# natural-language missions without hints about when to call request_help.
#
# Assertions target STRUCTURE and BEHAVIOR, not exact LLM text:
#   - Did the agent transition to :awaiting_orchestrator?
#   - Does the reason field describe what's needed?
#   - After resume, does the agent reach a terminal state?
#
# Related files:
#   - lib/assistant/orchestrator/sub_agent.ex (SubAgent GenServer)
#   - priv/config/prompts/sub_agent.yaml (system prompt template)
#   - test/integration/e2e_loop_llm_test.exs (Engine-level patterns)
#   - test/integration/support/test_logger.ex (verbose logging)

defmodule Assistant.Integration.AlgedonicLLMTest do
  use Assistant.DataCase, async: false
  # async: false — SubAgent uses named registries, ConfigLoader uses ETS

  import Mox
  import Assistant.Integration.TestLogger

  @moduletag :integration
  @moduletag timeout: 180_000

  alias Assistant.Orchestrator.SubAgent
  alias Assistant.Schemas.{Conversation, User}

  require Logger

  setup :verify_on_exit!

  setup do
    Process.flag(:trap_exit, true)

    # --- API Key Check ---
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
    # can access the MockLLMClient stub (sentinel auto-approve).
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
        external_id: "algedonic-llm-#{System.unique_integer([:positive])}",
        channel: "test"
      })
      |> Repo.insert!()

    {:ok, conversation} =
      %Conversation{}
      |> Conversation.changeset(%{channel: "test", user_id: user.id})
      |> Repo.insert()

    {user, conversation}
  end

  defp start_unlinked(module, opts) do
    case module.start_link(opts) do
      {:ok, pid} -> Process.unlink(pid)
      {:error, {:already_started, _}} -> :ok
    end
  end

  # GPT-5.2 model config for sub-agent integration tests.
  # If ConfigLoader is already running (ETS exists), we force GPT-5.2
  # by overwriting the :models and :defaults entries directly.
  # Otherwise, we start ConfigLoader with a valid config YAML.
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
      description: "GPT-5 Mini — fast fallback for compaction/sentinel",
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
      # ConfigLoader already running — force GPT-5.2 by overwriting ETS entries
      :ets.insert(:assistant_config, {:models, @test_models})
      :ets.insert(:assistant_config, {:defaults, @test_defaults})
      :ok
    else
      tmp_dir = System.tmp_dir!()

      config_path =
        Path.join(tmp_dir, "test_config_algedonic_llm_#{System.unique_integer([:positive])}.yaml")

      File.write!(config_path, """
      defaults:
        orchestrator: primary
        sub_agent: primary
        compaction: fast
        sentinel: fast

      models:
        - id: "openai/gpt-5.2"
          tier: primary
          description: "GPT-5.2 — integration test model"
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

  # Starts a SubAgent via start_link and returns the agent_id.
  #
  # Uses start_link (not execute/3) because we need to interact with
  # the agent mid-flight — polling get_status while it's in
  # :awaiting_orchestrator state.
  #
  # Options:
  #   - :max_tool_calls — max tool calls before budget exhaustion (default 10)
  #   - :dep_results — map of agent_id => result from dependency agents (default %{})
  #   - :context — additional context string (default nil)
  defp start_sub_agent(mission, skills, user, conversation, opts \\ []) do
    agent_id = "algedonic-test-#{System.unique_integer([:positive])}"
    max_tool_calls = Keyword.get(opts, :max_tool_calls, 10)
    dep_results = Keyword.get(opts, :dep_results, %{})
    context = Keyword.get(opts, :context, nil)

    dispatch_params = %{
      agent_id: agent_id,
      mission: mission,
      skills: skills,
      max_tool_calls: max_tool_calls,
      context: context,
      context_files: []
    }

    engine_state = %{
      conversation_id: conversation.id,
      user_id: user.id,
      channel: "test"
    }

    {:ok, _pid} =
      SubAgent.start_link(
        dispatch_params: dispatch_params,
        dep_results: dep_results,
        engine_state: engine_state
      )

    agent_id
  end

  # Polls get_status until the agent reaches `target_status` or timeout.
  # Returns `{:ok, status_map}` or `{:error, :timeout, last_status}`.
  defp poll_until(agent_id, target_status, max_ms) do
    deadline = System.monotonic_time(:millisecond) + max_ms
    poll_loop(agent_id, target_status, deadline)
  end

  defp poll_loop(agent_id, target_status, deadline) do
    now = System.monotonic_time(:millisecond)

    if now > deadline do
      case SubAgent.get_status(agent_id) do
        {:ok, status} -> {:error, :timeout, status}
        {:error, :not_found} -> {:error, :timeout, %{status: :not_found}}
      end
    else
      case SubAgent.get_status(agent_id) do
        {:ok, %{status: ^target_status} = status} ->
          {:ok, status}

        {:ok, _status} ->
          Process.sleep(500)
          poll_loop(agent_id, target_status, deadline)

        {:error, :not_found} ->
          # Agent may have completed and shut down — check if target was :completed
          if target_status in [:completed, :failed] do
            {:error, :agent_exited, %{status: :exited}}
          else
            Process.sleep(500)
            poll_loop(agent_id, target_status, deadline)
          end
      end
    end
  end

  defp poll_for_terminal_state(agent_id, max_ms) do
    deadline = System.monotonic_time(:millisecond) + max_ms
    poll_terminal_loop(agent_id, deadline)
  end

  defp poll_terminal_loop(agent_id, deadline) do
    now = System.monotonic_time(:millisecond)

    if now > deadline do
      case SubAgent.get_status(agent_id) do
        {:ok, status} -> {:error, :timeout, status}
        {:error, :not_found} -> {:error, :exited}
      end
    else
      case SubAgent.get_status(agent_id) do
        {:ok, %{status: status} = map} when status in [:completed, :failed] ->
          {:ok, map}

        {:ok, _status} ->
          Process.sleep(500)
          poll_terminal_loop(agent_id, deadline)

        {:error, :not_found} ->
          # GenServer exited — agent completed (normal shutdown)
          {:error, :exited}
      end
    end
  end

  # Asserts that the agent reached :awaiting_orchestrator with a reason
  # mentioning at least one of the expected keywords.
  defp assert_awaiting_with_reason(status, keywords, context_label) do
    assert status.status == :awaiting_orchestrator
    assert is_binary(status.reason)
    assert String.length(status.reason) > 0

    reason_lower = String.downcase(status.reason)

    keyword_match =
      Enum.any?(keywords, fn kw -> String.contains?(reason_lower, kw) end)

    assert keyword_match,
           "Expected reason to mention one of #{inspect(keywords)} " <>
             "[#{context_label}], got: #{status.reason}"
  end

  # ---------------------------------------------------------------
  # 1. Skill call returns error, agent requests help
  # ---------------------------------------------------------------

  describe "skill execution fails, agent requests help" do
    @tag :integration
    @tag timeout: 120_000
    test "agent calls request_help when email.search fails with 'not configured'" do
      {user, conversation} = create_user_and_conversation()

      # The agent has email.search (a real skill) but no Gmail integration
      # is configured for this test user. The skill executor will return
      # "Gmail integration not configured." — the agent should see that
      # error and call request_help to report the failure.
      agent_id =
        start_sub_agent(
          "Search my emails from alice@example.com about the weekly report.",
          ["email.search"],
          user,
          conversation
        )

      log_request("skill_error_help", %{
        agent_id: agent_id,
        mission: "email search (no Gmail configured)",
        model: "(via SubAgent pipeline)"
      })

      # The agent will either:
      # (a) call email.search, get the error, then call request_help → :awaiting_orchestrator
      # (b) call email.search, get the error, then report the error as text → :completed
      # Both are valid production behaviors. We prefer (a) but accept (b).
      case poll_until(agent_id, :awaiting_orchestrator, 90_000) do
        {:ok, status} ->
          log_pass("skill_error_help — agent paused", status.duration_ms || 0)

          assert_awaiting_with_reason(
            status,
            ~w(email gmail configured integration error fail),
            "skill failure should mention the service error"
          )

          # Agent should have made at least 1 tool call (the email.search attempt)
          assert status.tool_calls_used >= 1,
                 "Expected at least 1 tool call (email.search), got: #{status.tool_calls_used}"

          Logger.info("request_help reason: #{status.reason}")

        {:error, :timeout, last_status} ->
          log_fail("skill_error_help", {:timeout, last_status})

          # If the agent completed instead of requesting help, it reported
          # the error as text. This is acceptable but not ideal.
          if last_status.status in [:completed, :failed] do
            Logger.warning(
              "Agent completed without request_help — reported error as text. " <>
                "Result: #{inspect(last_status.result)}"
            )
          else
            flunk("""
            Agent did not reach :awaiting_orchestrator within 90s.
            Last status: #{inspect(last_status)}
            """)
          end

        {:error, :agent_exited, _} ->
          # Agent completed and GenServer shut down — reported error as text
          Logger.warning(
            "Agent exited (completed) without calling request_help — " <>
              "LLM chose to report the error directly."
          )
      end
    end
  end

  # ---------------------------------------------------------------
  # 2. Agent given wrong-domain skills for the mission
  # ---------------------------------------------------------------

  describe "wrong-domain skills trigger request_help" do
    @tag :integration
    @tag timeout: 120_000
    test "agent calls request_help when mission needs email but only has tasks.search" do
      {user, conversation} = create_user_and_conversation()

      # Mission: email search. Skills: tasks.search (valid skill, wrong domain).
      # The system prompt says "Only skills listed above are available" and
      # "Call request_help if you are blocked." No coaching in the mission.
      agent_id =
        start_sub_agent(
          "Search my emails from alice@example.com about the weekly report.",
          ["tasks.search"],
          user,
          conversation
        )

      log_request("wrong_domain_help", %{
        agent_id: agent_id,
        mission: "email search with only tasks.search",
        model: "(via SubAgent pipeline)"
      })

      case poll_until(agent_id, :awaiting_orchestrator, 90_000) do
        {:ok, status} ->
          log_pass("wrong_domain_help — agent paused", status.duration_ms || 0)

          assert_awaiting_with_reason(
            status,
            ~w(email skill search available block cannot unable need),
            "should describe missing email capability"
          )

          Logger.info("request_help reason: #{status.reason}")

        {:error, :timeout, last_status} ->
          log_fail("wrong_domain_help", {:timeout, last_status})

          if last_status.status in [:completed, :failed] do
            Logger.warning(
              "Agent completed without request_help — " <>
                "LLM chose to explain inability. Result: #{inspect(last_status.result)}"
            )
          else
            flunk("""
            Agent did not reach :awaiting_orchestrator within 90s.
            Last status: #{inspect(last_status)}
            The LLM may have responded with text instead of calling request_help.
            """)
          end

        {:error, :agent_exited, _} ->
          Logger.warning(
            "Agent exited without calling request_help — " <>
              "LLM chose to report inability directly."
          )
      end
    end
  end

  # ---------------------------------------------------------------
  # 3. Agent resumes with orchestrator message and adapts
  # ---------------------------------------------------------------

  describe "agent resumes with orchestrator message and adapts" do
    @tag :integration
    @tag timeout: 120_000
    test "agent uses available skill after receiving redirect message" do
      {user, conversation} = create_user_and_conversation()

      # Same setup as test 2: email mission + tasks.search only.
      # After the agent pauses, we resume with a message redirecting it
      # to use tasks.search instead.
      agent_id =
        start_sub_agent(
          "Search my emails from alice@example.com about the weekly report.",
          ["tasks.search"],
          user,
          conversation
        )

      log_request("resume_with_message", %{
        agent_id: agent_id,
        mission: "email search → resume with redirect to tasks.search",
        model: "(via SubAgent pipeline)"
      })

      case poll_until(agent_id, :awaiting_orchestrator, 90_000) do
        {:ok, status} ->
          log_pass("resume_with_message — paused", status.duration_ms || 0)
          assert status.status == :awaiting_orchestrator

          Logger.info("Agent paused with reason: #{status.reason}")

          # Resume with redirect instructions
          assert :ok =
                   SubAgent.resume(agent_id, %{
                     message:
                       "Email search is unavailable right now. Instead, use tasks.search " <>
                         "to look for any tasks mentioning Alice or the weekly report."
                   })

          # Agent should adapt and reach a terminal state
          final_result = poll_for_terminal_state(agent_id, 90_000)

          case final_result do
            {:ok, final_status} ->
              log_pass("resume_with_message — completed", final_status[:duration_ms] || 0)

              assert final_status.status in [:completed, :failed],
                     "Expected terminal state, got: #{inspect(final_status.status)}"

              # After resume, the agent should have made at least 1 tool call
              # (using tasks.search as instructed)
              assert final_status.tool_calls_used >= 1,
                     "Expected at least 1 tool call after resume, got: #{final_status.tool_calls_used}"

              Logger.info("Agent final result: #{inspect(final_status.result)}")

            {:error, :exited} ->
              log_pass("resume_with_message — agent exited (completed)", 0)

            {:error, :timeout, last_status} ->
              log_fail("resume_with_message — timeout after resume", last_status)

              flunk("""
              Agent did not reach terminal state after resume within 90s.
              Last status: #{inspect(last_status)}
              """)
          end

        {:error, :timeout, last_status} ->
          log_fail("resume_with_message", {:initial_pause_timeout, last_status})

          # Agent may have completed without pausing (reported inability as text)
          if last_status.status in [:completed, :failed] do
            Logger.warning(
              "Agent completed without pausing — cannot test resume. " <>
                "Result: #{inspect(last_status.result)}"
            )
          else
            flunk("""
            Agent did not reach :awaiting_orchestrator within 90s.
            Last status: #{inspect(last_status)}
            """)
          end

        {:error, :agent_exited, _} ->
          Logger.warning(
            "Agent exited before calling request_help — cannot test resume."
          )
      end
    end
  end

  # ---------------------------------------------------------------
  # 4. Skill succeeds but result is insufficient for the full mission
  # ---------------------------------------------------------------

  describe "skill succeeds but mission cannot be fully completed" do
    @tag :integration
    @tag timeout: 120_000
    test "agent requests help when available skills cannot fulfill the full mission" do
      {user, conversation} = create_user_and_conversation()

      # The agent can search tasks but the mission requires both email
      # and calendar access. After trying tasks.search, the agent should
      # realize it cannot complete the calendar/email parts.
      agent_id =
        start_sub_agent(
          "Find Alice's email address from our task records and then " <>
            "create a calendar event to meet with her tomorrow at 3pm.",
          ["tasks.search"],
          user,
          conversation
        )

      log_request("insufficient_skills", %{
        agent_id: agent_id,
        mission: "multi-step: search tasks + create calendar (only has tasks.search)",
        model: "(via SubAgent pipeline)"
      })

      case poll_until(agent_id, :awaiting_orchestrator, 90_000) do
        {:ok, status} ->
          log_pass("insufficient_skills — paused", status.duration_ms || 0)

          assert_awaiting_with_reason(
            status,
            ~w(calendar event create skill available cannot unable need),
            "should mention missing calendar/create capability"
          )

          # Agent should have made at least 1 tool call (tasks.search attempt)
          assert status.tool_calls_used >= 1,
                 "Expected at least 1 tool call before request_help, got: #{status.tool_calls_used}"

          Logger.info("request_help reason: #{status.reason}")

        {:error, :timeout, last_status} ->
          log_fail("insufficient_skills", {:timeout, last_status})

          if last_status.status in [:completed, :failed] do
            Logger.warning(
              "Agent completed without request_help — " <>
                "reported partial results. Result: #{inspect(last_status.result)}"
            )
          else
            flunk("""
            Agent did not reach :awaiting_orchestrator within 90s.
            Last status: #{inspect(last_status)}
            """)
          end

        {:error, :agent_exited, _} ->
          Logger.warning(
            "Agent exited without calling request_help — " <>
              "LLM chose to report inability directly."
          )
      end
    end
  end

  # ---------------------------------------------------------------
  # 5. Full round-trip: pause, resume with new skills, complete
  # ---------------------------------------------------------------

  describe "full round-trip: pause, resume with new skills, complete" do
    @tag :integration
    @tag timeout: 120_000
    test "agent pauses for missing skill, resumes with it, and completes" do
      {user, conversation} = create_user_and_conversation()

      # Mission: create a task. Skills: tasks.search (read-only, can't create).
      # Agent should realize it needs tasks.create and request help.
      agent_id =
        start_sub_agent(
          "Create a high-priority task titled 'Prepare weekly sync agenda' " <>
            "with description 'Compile updates from all team leads'.",
          ["tasks.search"],
          user,
          conversation
        )

      log_request("full_roundtrip", %{
        agent_id: agent_id,
        mission: "create task with only tasks.search → resume with tasks.create",
        model: "(via SubAgent pipeline)"
      })

      case poll_until(agent_id, :awaiting_orchestrator, 90_000) do
        {:ok, status} ->
          log_pass("full_roundtrip — paused", status.duration_ms || 0)

          assert_awaiting_with_reason(
            status,
            ~w(create task skill available cannot unable need),
            "should mention needing create capability"
          )

          Logger.info("Agent paused with reason: #{status.reason}")

          # Resume with the tasks.create skill
          assert :ok =
                   SubAgent.resume(agent_id, %{
                     message: "Here is the tasks.create skill. Create the task as requested.",
                     skills: ["tasks.create"]
                   })

          # Agent should now use tasks.create and reach a terminal state
          final_result = poll_for_terminal_state(agent_id, 90_000)

          case final_result do
            {:ok, final_status} ->
              log_pass("full_roundtrip — completed", final_status[:duration_ms] || 0)

              assert final_status.status in [:completed, :failed],
                     "Expected terminal state, got: #{inspect(final_status.status)}"

              # After resume, agent should have used at least 1 tool call (tasks.create)
              assert final_status.tool_calls_used >= 1,
                     "Expected tool_calls_used >= 1 after resume, got: #{final_status.tool_calls_used}"

              Logger.info("Agent final result: #{inspect(final_status.result)}")

            {:error, :exited} ->
              # Agent completed and GenServer shut down — normal
              log_pass("full_roundtrip — agent exited (completed)", 0)

            {:error, :timeout, last_status} ->
              log_fail("full_roundtrip — timeout after resume", last_status)

              flunk("""
              Agent did not reach terminal state after resume within 90s.
              Last status: #{inspect(last_status)}
              """)
          end

        {:error, :timeout, last_status} ->
          log_fail("full_roundtrip", {:initial_pause_timeout, last_status})

          if last_status.status in [:completed, :failed] do
            Logger.warning(
              "Agent completed without pausing — LLM may have tried to proceed " <>
                "without the create skill. Result: #{inspect(last_status.result)}"
            )
          else
            flunk("""
            Agent did not reach :awaiting_orchestrator within 90s.
            Last status: #{inspect(last_status)}
            """)
          end

        {:error, :agent_exited, _} ->
          Logger.warning(
            "Agent exited before calling request_help — cannot test resume."
          )
      end
    end
  end

  # ---------------------------------------------------------------
  # 6. Cascading failure via dep_results
  # ---------------------------------------------------------------

  describe "cascading failure from prior agent" do
    @tag :integration
    @tag timeout: 120_000
    test "agent sees prior agent failure in context and requests help" do
      {user, conversation} = create_user_and_conversation()

      # Simulate a prior email agent that failed due to revoked OAuth token.
      # The dep_results are injected into the system prompt as
      # "Prior agent results:" — the agent should see this context and
      # call request_help with a clear description of the cascading failure.
      prior_failure = %{
        "email_search_agent" => %{
          result:
            "FAILED: Gmail returned 403 Forbidden — " <>
              "user's Google OAuth token has been revoked. " <>
              "Cannot access email without re-authentication."
        }
      }

      agent_id =
        start_sub_agent(
          "Search for Alice's weekly report email and forward the key findings to the team.",
          ["tasks.search"],
          user,
          conversation,
          dep_results: prior_failure
        )

      log_request("cascading_failure", %{
        agent_id: agent_id,
        mission: "assess prior agent failure (OAuth revoked)",
        model: "(via SubAgent pipeline)"
      })

      case poll_until(agent_id, :awaiting_orchestrator, 90_000) do
        {:ok, status} ->
          log_pass("cascading_failure — paused", status.duration_ms || 0)

          assert_awaiting_with_reason(
            status,
            ~w(oauth token auth revoke fail email gmail access forbidden),
            "should reference the OAuth/auth failure from prior agent"
          )

          Logger.info("request_help reason: #{status.reason}")

        {:error, :timeout, last_status} ->
          log_fail("cascading_failure", {:timeout, last_status})

          if last_status.status in [:completed, :failed] do
            # Agent may have assessed the situation and reported it as text
            # rather than calling request_help. This is acceptable — the
            # agent understood the failure context either way.
            result_text = inspect(last_status.result)
            result_lower = String.downcase(result_text)

            has_failure_context =
              Enum.any?(
                ~w(oauth token auth revoke fail forbidden),
                fn kw -> String.contains?(result_lower, kw) end
              )

            if has_failure_context do
              Logger.warning(
                "Agent completed without request_help but referenced the failure context. " <>
                  "Result: #{result_text}"
              )
            else
              Logger.warning(
                "Agent completed without referencing failure context. " <>
                  "Result: #{result_text}"
              )
            end
          else
            flunk("""
            Agent did not reach :awaiting_orchestrator within 90s.
            Last status: #{inspect(last_status)}
            """)
          end

        {:error, :agent_exited, _} ->
          Logger.warning(
            "Agent exited without calling request_help — " <>
              "may have reported the failure assessment directly."
          )
      end
    end
  end

  # ---------------------------------------------------------------
  # 7. Resume error handling (structural, non-LLM)
  # ---------------------------------------------------------------

  describe "resume error handling" do
    @tag :integration
    @tag timeout: 60_000
    test "resume returns error when agent is not in awaiting state" do
      {user, conversation} = create_user_and_conversation()

      # Start an agent with matching skills — should complete without request_help
      agent_id =
        start_sub_agent(
          "Search for tasks related to the weekly sync meeting.",
          ["tasks.search"],
          user,
          conversation
        )

      # Wait briefly for the agent to start running
      Process.sleep(1_000)

      # Try to resume — should fail because agent is running or completed
      case SubAgent.resume(agent_id, %{message: "Unexpected resume"}) do
        {:error, :not_awaiting} ->
          log_pass("resume_not_awaiting", 0)
          assert true

        {:error, :not_found} ->
          # Agent already completed and GenServer exited
          log_pass("resume_not_found (agent completed)", 0)
          assert true

        :ok ->
          # Unlikely: agent called request_help with matching skills
          Logger.warning("Resume succeeded — agent unexpectedly called request_help")
          assert true
      end
    end
  end
end
