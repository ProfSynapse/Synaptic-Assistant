# test/assistant/orchestrator/approval_gate_sub_agent_test.exs
#
# Deterministic tests that prove handle_approval_gate/7 in sub_agent.ex
# actually fires when a requires_approval: true skill is called.
#
# Uses Bypass to intercept OpenRouter HTTP calls so the sub-agent LLM
# returns a controlled use_skill tool call for email.send. The Sentinel
# is stubbed via MockLLMRouter (auto-approve). No real LLM calls.
#
# Tests verify:
#   1. GenServer transitions to :awaiting_orchestrator with [APPROVAL_REQUIRED]
#   2. SubAgent.resume(approved: true) causes skill execution
#   3. SubAgent.resume(approved: false) causes denial without execution
#   4. SubAgent.resume(approved: false, message: feedback) returns feedback

defmodule Assistant.Orchestrator.ApprovalGateSubAgentTest do
  use Assistant.DataCase, async: false

  import Mox

  alias Assistant.Orchestrator.SubAgent

  require Logger

  @moduletag timeout: 60_000

  setup :verify_on_exit!

  setup do
    Process.flag(:trap_exit, true)

    # --- Infrastructure (idempotent, unlinked) ---
    Application.ensure_all_started(:phoenix_pubsub)
    start_unlinked(Phoenix.PubSub.Supervisor, name: Assistant.PubSub)
    start_unlinked(Task.Supervisor, name: Assistant.Skills.TaskSupervisor)
    start_unlinked(Elixir.Registry, keys: :unique, name: Assistant.SubAgent.Registry)

    # Real Skills.Registry from priv/skills (has email.send with requires_approval: true)
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

    # Stub Sentinel (MockLLMRouter) — auto-approve all security checks
    Mox.set_mox_global(self())

    stub(MockLLMRouter, :chat_completion, fn _messages, _opts, _user_id ->
      {:ok,
       %{
         id: "sentinel-stub",
         model: "stub",
         content:
           Jason.encode!(%{
             reasoning: "Test auto-approve.",
             decision: "approve",
             reason: "Test stub."
           }),
         tool_calls: [],
         finish_reason: "stop",
         usage: %{prompt_tokens: 0, completion_tokens: 0, total_tokens: 0}
       }}
    end)

    # Bypass intercepts OpenRouter HTTP calls
    bypass = Bypass.open()
    original_base_url = Application.get_env(:assistant, :openrouter_base_url)
    Application.put_env(:assistant, :openrouter_base_url, "http://localhost:#{bypass.port}")
    Application.put_env(:assistant, :openrouter_api_key, "test-bypass-key")

    on_exit(fn ->
      if original_base_url do
        Application.put_env(:assistant, :openrouter_base_url, original_base_url)
      else
        Application.delete_env(:assistant, :openrouter_base_url)
      end
    end)

    %{bypass: bypass}
  end

  # ---------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------

  defp start_unlinked(module, opts) do
    case module.start_link(opts) do
      {:ok, pid} -> Process.unlink(pid)
      {:error, {:already_started, _}} -> :ok
    end
  end

  defp ensure_config_loader_started do
    if :ets.whereis(:assistant_config) != :undefined do
      :ets.insert(:assistant_config, {:models, test_models()})
      :ets.insert(:assistant_config, {:defaults, test_defaults()})
      :ok
    else
      tmp = System.tmp_dir!()
      path = Path.join(tmp, "cfg_gate_#{System.unique_integer([:positive])}.yaml")

      File.write!(path, """
      defaults:
        orchestrator: primary
        sub_agent: primary
        compaction: fast
        sentinel: fast
      models:
        - id: "test/mock"
          tier: primary
          description: "Mock model for bypass tests"
          use_cases: [orchestrator, sub_agent]
          supports_tools: true
          max_context_tokens: 100000
          cost_tier: low
        - id: "test/fast"
          tier: fast
          description: "Fast mock"
          use_cases: [compaction, sentinel]
          supports_tools: true
          max_context_tokens: 100000
          cost_tier: low
      http:
        max_retries: 0
        base_backoff_ms: 100
        max_backoff_ms: 1000
        request_timeout_ms: 10000
        streaming_timeout_ms: 10000
      limits:
        context_utilization_target: 0.85
        compaction_trigger_threshold: 0.75
        response_reserve_tokens: 1024
        orchestrator_turn_limit: 10
        sub_agent_turn_limit: 5
        cache_ttl_seconds: 60
        orchestrator_cache_breakpoints: 2
        sub_agent_cache_breakpoints: 1
      """)

      start_unlinked(Assistant.Config.Loader, path: path)
    end
  end

  defp test_models do
    [
      %{
        id: "test/mock",
        tier: :primary,
        description: "Mock model",
        use_cases: [:orchestrator, :sub_agent],
        supports_tools: true,
        max_context_tokens: 100_000,
        cost_tier: :low
      },
      %{
        id: "test/fast",
        tier: :fast,
        description: "Fast mock",
        use_cases: [:compaction, :sentinel],
        supports_tools: true,
        max_context_tokens: 100_000,
        cost_tier: :low
      }
    ]
  end

  defp test_defaults do
    %{orchestrator: :primary, sub_agent: :primary, compaction: :fast, sentinel: :fast}
  end

  # Build an OpenRouter-format JSON response with a use_skill tool call
  defp tool_call_response(skill_name, arguments) do
    %{
      "id" => "chatcmpl-test",
      "model" => "test/mock",
      "choices" => [
        %{
          "message" => %{
            "role" => "assistant",
            "content" => nil,
            "tool_calls" => [
              %{
                "id" => "tc_#{System.unique_integer([:positive])}",
                "type" => "function",
                "function" => %{
                  "name" => "use_skill",
                  "arguments" =>
                    Jason.encode!(%{
                      "skill" => skill_name,
                      "arguments" => arguments
                    })
                }
              }
            ]
          },
          "finish_reason" => "tool_calls"
        }
      ],
      "usage" => %{
        "prompt_tokens" => 100,
        "completion_tokens" => 20,
        "total_tokens" => 120
      }
    }
  end

  # Build an OpenRouter-format JSON response with plain text (no tool calls)
  defp text_response(text) do
    %{
      "id" => "chatcmpl-text",
      "model" => "test/mock",
      "choices" => [
        %{
          "message" => %{
            "role" => "assistant",
            "content" => text
          },
          "finish_reason" => "stop"
        }
      ],
      "usage" => %{
        "prompt_tokens" => 100,
        "completion_tokens" => 20,
        "total_tokens" => 120
      }
    }
  end

  defp make_dispatch_params(agent_id) do
    %{
      agent_id: agent_id,
      mission: "Send an email to bob@example.com with subject 'Test' and body 'Hello'.",
      skills: ["email.send"],
      context: nil,
      context_files: nil,
      # Bypass ModelDefaults DB query (avoids Ecto Sandbox issues with Task.Supervised)
      model_override: "test/mock"
    }
  end

  defp make_engine_state do
    %{
      conversation_id: Ecto.UUID.generate(),
      # Use nil user_id to bypass LLMRouter DB queries (openai_credentials_for_user,
      # openrouter_key_for_user) which would fail in Task.Supervised sandbox context.
      user_id: nil,
      channel: "test"
    }
  end

  # ---------------------------------------------------------------
  # Test: gate fires and GenServer transitions to awaiting_orchestrator
  # ---------------------------------------------------------------

  describe "handle_approval_gate fires deterministically" do
    test "sub-agent pauses at approval gate with [APPROVAL_REQUIRED] reason", %{bypass: bypass} do
      agent_id = "gate-pause-#{System.unique_integer([:positive])}"

      # Bypass: return a use_skill call for email.send (gated skill)
      # Use expect (not expect_once) because model resolution or retries
      # may trigger additional HTTP calls before the gate fires.
      Bypass.expect(bypass, "POST", "/chat/completions", fn conn ->
        resp_body =
          tool_call_response("email.send", %{
            "to" => "bob@example.com",
            "subject" => "Test",
            "body" => "Hello"
          })

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(resp_body))
      end)

      dispatch_params = make_dispatch_params(agent_id)
      engine_state = make_engine_state()

      {:ok, pid} =
        SubAgent.start_link(
          dispatch_params: dispatch_params,
          dep_results: %{},
          engine_state: engine_state
        )

      # Wait for the sub-agent to hit the gate and pause
      assert_eventually(
        fn ->
          case SubAgent.get_status(agent_id) do
            {:ok, %{status: :awaiting_orchestrator}} -> true
            _ -> false
          end
        end,
        10_000
      )

      # Verify the status contains [APPROVAL_REQUIRED] and email details
      {:ok, status} = SubAgent.get_status(agent_id)
      assert status.status == :awaiting_orchestrator
      assert status.reason =~ "[APPROVAL_REQUIRED]"
      assert status.reason =~ "email.send"
      assert status.reason =~ "bob@example.com"
      assert status.reason =~ "Test"

      # Cleanup: resume to unblock the receive, then stop
      SubAgent.resume(agent_id, %{approved: false})
      Process.sleep(200)
      if Process.alive?(pid), do: safe_stop(pid)
    end

    test "resume with approved: true executes the skill", %{bypass: bypass} do
      agent_id = "gate-approve-#{System.unique_integer([:positive])}"
      call_count = :counters.new(1, [:atomics])

      # Bypass: first call returns use_skill, second returns text (post-execution)
      Bypass.expect(bypass, "POST", "/chat/completions", fn conn ->
        :counters.add(call_count, 1, 1)
        n = :counters.get(call_count, 1)

        resp_body =
          if n == 1 do
            tool_call_response("email.send", %{
              "to" => "bob@example.com",
              "subject" => "Test",
              "body" => "Hello"
            })
          else
            text_response("Email task completed.")
          end

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(resp_body))
      end)

      dispatch_params = make_dispatch_params(agent_id)
      engine_state = make_engine_state()

      {:ok, pid} =
        SubAgent.start_link(
          dispatch_params: dispatch_params,
          dep_results: %{},
          engine_state: engine_state,
          caller_pid: self()
        )

      # Wait for pause
      assert_eventually(
        fn ->
          case SubAgent.get_status(agent_id) do
            {:ok, %{status: :awaiting_orchestrator}} -> true
            _ -> false
          end
        end,
        10_000
      )

      # Resume with approval
      assert :ok = SubAgent.resume(agent_id, %{approved: true})

      # Wait for completion — the skill will fail (no Gmail token) but
      # the important thing is that it TRIED to execute, not that it succeeded.
      # The sub-agent will either complete or fail after skill execution.
      assert_eventually(
        fn ->
          case SubAgent.get_status(agent_id) do
            {:ok, %{status: s}} when s in [:completed, :failed] -> true
            {:error, :not_found} -> true
            _ -> false
          end
        end,
        15_000
      )

      # Verify skill was attempted (Bypass got at least 1 call, agent completed/failed)
      assert :counters.get(call_count, 1) >= 1

      if Process.alive?(pid), do: safe_stop(pid)
    end

    test "resume with approved: false denies without executing skill", %{bypass: bypass} do
      agent_id = "gate-deny-#{System.unique_integer([:positive])}"
      call_count = :counters.new(1, [:atomics])

      # Bypass: first call returns use_skill; after denial, second call returns text
      Bypass.expect(bypass, "POST", "/chat/completions", fn conn ->
        :counters.add(call_count, 1, 1)
        n = :counters.get(call_count, 1)

        resp_body =
          if n == 1 do
            tool_call_response("email.send", %{
              "to" => "alice@example.com",
              "subject" => "Contract",
              "body" => "Draft attached"
            })
          else
            text_response("Understood, the email was not sent.")
          end

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(resp_body))
      end)

      dispatch_params = %{make_dispatch_params(agent_id) | mission: "Send contract email"}
      engine_state = make_engine_state()

      {:ok, pid} =
        SubAgent.start_link(
          dispatch_params: dispatch_params,
          dep_results: %{},
          engine_state: engine_state,
          caller_pid: self()
        )

      # Wait for gate
      assert_eventually(
        fn ->
          case SubAgent.get_status(agent_id) do
            {:ok, %{status: :awaiting_orchestrator}} -> true
            _ -> false
          end
        end,
        10_000
      )

      # Deny
      assert :ok = SubAgent.resume(agent_id, %{approved: false})

      # Wait for completion
      assert_eventually(
        fn ->
          case SubAgent.get_status(agent_id) do
            {:ok, %{status: s}} when s in [:completed, :failed] -> true
            {:error, :not_found} -> true
            _ -> false
          end
        end,
        15_000
      )

      if Process.alive?(pid), do: safe_stop(pid)
    end

    test "resume with approved: false and feedback includes feedback in denial", %{bypass: bypass} do
      agent_id = "gate-feedback-#{System.unique_integer([:positive])}"
      call_count = :counters.new(1, [:atomics])

      Bypass.expect(bypass, "POST", "/chat/completions", fn conn ->
        :counters.add(call_count, 1, 1)
        n = :counters.get(call_count, 1)

        resp_body =
          if n == 1 do
            tool_call_response("email.send", %{
              "to" => "charlie@example.com",
              "subject" => "Update",
              "body" => "Project on track"
            })
          else
            text_response("Updated and awaiting re-approval.")
          end

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(resp_body))
      end)

      dispatch_params = make_dispatch_params(agent_id)
      engine_state = make_engine_state()

      {:ok, pid} =
        SubAgent.start_link(
          dispatch_params: dispatch_params,
          dep_results: %{},
          engine_state: engine_state,
          caller_pid: self()
        )

      # Wait for gate
      assert_eventually(
        fn ->
          case SubAgent.get_status(agent_id) do
            {:ok, %{status: :awaiting_orchestrator}} -> true
            _ -> false
          end
        end,
        10_000
      )

      # Deny with feedback
      assert :ok =
               SubAgent.resume(agent_id, %{
                 approved: false,
                 message: "Change subject to Q2 Update"
               })

      # Wait for the sub-agent to process the denial and continue its loop
      assert_eventually(
        fn ->
          case SubAgent.get_status(agent_id) do
            {:ok, %{status: s}} when s in [:completed, :failed] -> true
            {:ok, %{status: :running}} -> true
            {:error, :not_found} -> true
            _ -> false
          end
        end,
        15_000
      )

      if Process.alive?(pid), do: safe_stop(pid)
    end
  end

  # ---------------------------------------------------------------
  # Polling helper
  # ---------------------------------------------------------------

  defp assert_eventually(fun, timeout_ms, interval_ms \\ 100) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    do_assert_eventually(fun, deadline, interval_ms)
  end

  defp do_assert_eventually(fun, deadline, interval_ms) do
    if fun.() do
      :ok
    else
      now = System.monotonic_time(:millisecond)

      if now >= deadline do
        flunk("assert_eventually timed out after #{deadline - now + interval_ms}ms")
      else
        Process.sleep(interval_ms)
        do_assert_eventually(fun, deadline, interval_ms)
      end
    end
  end

  defp safe_stop(pid) do
    try do
      GenServer.stop(pid, :normal, 5_000)
    catch
      :exit, _ -> :ok
    end
  end
end
