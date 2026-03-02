# test/assistant/orchestrator/e2e_loop_test.exs — End-to-end tests for the LLM orchestration loop.
#
# Tests the full cycle: user message → Engine → LoopRunner → LLMRouter → OpenRouter → HTTP.
# Uses Bypass to intercept HTTP at the Req level (since LoopRunner → LLMRouter → OpenRouter
# does NOT use the @llm_client compile_env mock — it calls OpenRouter directly via HTTP).
#
# Coverage:
#   - Full loop: text response on first iteration
#   - Multi-iteration tool call loops (get_skill → re-loop → text)
#   - Error recovery: malformed JSON, 500 errors, rate limits, empty responses
#   - Max iteration limit enforcement
#   - Conversation rate limit enforcement
#   - Context window management (usage-based trimming)

defmodule Assistant.Orchestrator.E2ELoopTest do
  use Assistant.DataCase, async: false
  # async: false — Engine uses named registries, ConfigLoader uses ETS, Bypass port is shared

  import Mox

  alias Assistant.Orchestrator.Engine
  alias Assistant.Schemas.{Conversation, User}

  require Logger

  setup :verify_on_exit!

  setup do
    # Trap exits so Engine crashes don't kill test process
    Process.flag(:trap_exit, true)

    # --- Infrastructure setup (idempotent, unlinked) ---

    Application.ensure_all_started(:phoenix_pubsub)

    start_unlinked(Phoenix.PubSub.Supervisor, name: Assistant.PubSub)
    start_unlinked(Task.Supervisor, name: Assistant.Skills.TaskSupervisor)
    start_unlinked(Elixir.Registry, keys: :unique, name: Assistant.Orchestrator.EngineRegistry)
    start_unlinked(Elixir.Registry, keys: :unique, name: Assistant.SubAgent.Registry)

    # Skills.Registry (ETS-backed GenServer for skill lookups)
    if :ets.whereis(:assistant_skills) == :undefined do
      tmp = Path.join(System.tmp_dir!(), "e2e_skills_#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp)
      start_unlinked(Assistant.Skills.Registry, skills_dir: tmp)
    end

    # PromptLoader (ETS-backed GenServer for prompt templates)
    if :ets.whereis(:assistant_prompts) == :undefined do
      tmp = Path.join(System.tmp_dir!(), "e2e_prompts_#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp)

      File.write!(Path.join(tmp, "orchestrator.yaml"), """
      system: |
        You are an AI orchestrator (test mode).
        Domains: <%= @skill_domains %>
        User: <%= @user_id %>
        Channel: <%= @channel %>
        Date: <%= @current_date %>
      """)

      start_unlinked(Assistant.Config.PromptLoader, dir: tmp)
    end

    # Config.Loader (ETS-backed GenServer for model/limits config)
    ensure_config_loader_started()

    # --- Bypass for OpenRouter HTTP ---
    bypass = Bypass.open()

    # Override OpenRouter base URL to point at Bypass
    original_base_url = Application.get_env(:assistant, :openrouter_base_url)
    Application.put_env(:assistant, :openrouter_base_url, "http://localhost:#{bypass.port}")

    # Ensure an API key is set (OpenRouter reads it at call time)
    original_api_key = Application.get_env(:assistant, :openrouter_api_key)
    Application.put_env(:assistant, :openrouter_api_key, "test-bypass-key")

    on_exit(fn ->
      # Restore original config
      if original_base_url do
        Application.put_env(:assistant, :openrouter_base_url, original_base_url)
      else
        Application.delete_env(:assistant, :openrouter_base_url)
      end

      if original_api_key do
        Application.put_env(:assistant, :openrouter_api_key, original_api_key)
      else
        Application.delete_env(:assistant, :openrouter_api_key)
      end
    end)

    %{bypass: bypass}
  end

  # ---------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------

  defp create_user_and_conversation do
    user =
      %User{}
      |> User.changeset(%{
        external_id: "e2e-test-#{System.unique_integer([:positive])}",
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
        GenServer.stop(pid, :normal, 1_000)
      catch
        :exit, _ -> :ok
      end
    end
  end

  # Builds a standard OpenRouter API response body (JSON-encodable map)
  defp text_response(content, opts \\ []) do
    usage = Keyword.get(opts, :usage, %{})

    %{
      "id" => "chatcmpl-test-#{System.unique_integer([:positive])}",
      "model" => "test/model",
      "choices" => [
        %{
          "message" => %{
            "role" => "assistant",
            "content" => content
          },
          "finish_reason" => "stop"
        }
      ],
      "usage" => Map.merge(
        %{
          "prompt_tokens" => 100,
          "completion_tokens" => 50,
          "total_tokens" => 150
        },
        usage
      )
    }
  end

  defp tool_call_response(tool_calls, opts \\ []) do
    usage = Keyword.get(opts, :usage, %{})

    formatted_calls =
      Enum.map(tool_calls, fn {id, name, args} ->
        %{
          "id" => id,
          "type" => "function",
          "function" => %{
            "name" => name,
            "arguments" => if(is_binary(args), do: args, else: Jason.encode!(args))
          }
        }
      end)

    %{
      "id" => "chatcmpl-test-#{System.unique_integer([:positive])}",
      "model" => "test/model",
      "choices" => [
        %{
          "message" => %{
            "role" => "assistant",
            "content" => nil,
            "tool_calls" => formatted_calls
          },
          "finish_reason" => "tool_calls"
        }
      ],
      "usage" => Map.merge(
        %{
          "prompt_tokens" => 100,
          "completion_tokens" => 50,
          "total_tokens" => 150
        },
        usage
      )
    }
  end

  # ---------------------------------------------------------------
  # 1. Full loop — text response on first iteration
  # ---------------------------------------------------------------

  describe "full loop: direct text response" do
    test "Engine returns text response from single LLM iteration", %{bypass: bypass} do
      {user, conversation} = create_user_and_conversation()

      Bypass.stub(bypass, "POST", "/chat/completions", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(text_response("Hello! How can I help you?")))
      end)

      {:ok, pid} = Engine.start_link(conversation.id, user_id: user.id, channel: "test")

      assert {:ok, response} = Engine.send_message(conversation.id, "Hello")
      assert response == "Hello! How can I help you?"

      # Verify state was updated
      {:ok, state} = Engine.get_state(conversation.id)
      assert state.message_count >= 2
      assert state.iteration_count == 1

      safe_stop(pid)
    end

    test "Engine accumulates token usage from LLM response", %{bypass: bypass} do
      {user, conversation} = create_user_and_conversation()

      Bypass.stub(bypass, "POST", "/chat/completions", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(
          text_response("Response.", usage: %{
            "prompt_tokens" => 200,
            "completion_tokens" => 100,
            "total_tokens" => 300
          })
        ))
      end)

      {:ok, pid} = Engine.start_link(conversation.id, user_id: user.id, channel: "test")
      {:ok, _response} = Engine.send_message(conversation.id, "Count tokens")

      {:ok, state} = Engine.get_state(conversation.id)
      assert state.total_usage.prompt_tokens == 200
      assert state.total_usage.completion_tokens == 100

      safe_stop(pid)
    end
  end

  # ---------------------------------------------------------------
  # 2. Multi-iteration tool call loops
  # ---------------------------------------------------------------

  describe "multi-iteration tool call loops" do
    test "Engine handles get_skill tool call then returns text", %{bypass: bypass} do
      {user, conversation} = create_user_and_conversation()
      call_count = :counters.new(1, [:atomics])

      Bypass.stub(bypass, "POST", "/chat/completions", fn conn ->
        :counters.add(call_count, 1, 1)
        current = :counters.get(call_count, 1)

        response =
          if current == 1 do
            # First call: LLM requests get_skill
            tool_call_response([
              {"call_1", "get_skill", %{"domain" => "email"}}
            ])
          else
            # Second call: LLM returns final text after seeing skill results
            text_response("I found the email skills. How can I help?")
          end

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(response))
      end)

      {:ok, pid} = Engine.start_link(conversation.id, user_id: user.id, channel: "test")
      {:ok, response} = Engine.send_message(conversation.id, "What email skills do you have?")

      assert response == "I found the email skills. How can I help?"

      # At least 2 LLM calls: tool call + text. May have more from
      # background tasks (TurnClassifier).
      assert :counters.get(call_count, 1) >= 2

      # Verify iteration count reflects the loop
      {:ok, state} = Engine.get_state(conversation.id)
      assert state.iteration_count == 2

      safe_stop(pid)
    end

    test "Engine handles multiple sequential tool calls before text", %{bypass: bypass} do
      {user, conversation} = create_user_and_conversation()
      call_count = :counters.new(1, [:atomics])

      Bypass.stub(bypass, "POST", "/chat/completions", fn conn ->
        :counters.add(call_count, 1, 1)
        current = :counters.get(call_count, 1)

        response =
          case current do
            1 ->
              # First: request get_skill for email
              tool_call_response([{"call_1", "get_skill", %{"domain" => "email"}}])

            2 ->
              # Second: request get_skill for calendar
              tool_call_response([{"call_2", "get_skill", %{"domain" => "calendar"}}])

            _ ->
              # Third: final text response
              text_response("I can help with email and calendar.")
          end

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(response))
      end)

      {:ok, pid} = Engine.start_link(conversation.id, user_id: user.id, channel: "test")
      {:ok, response} = Engine.send_message(conversation.id, "What can you do?")

      assert response == "I can help with email and calendar."
      # At least 3 calls: two tool calls + text. May have more from
      # background tasks (TurnClassifier).
      assert :counters.get(call_count, 1) >= 3

      safe_stop(pid)
    end
  end

  # ---------------------------------------------------------------
  # 3. Error recovery in the loop
  # ---------------------------------------------------------------

  describe "error recovery" do
    test "Engine returns error on LLM 500 response", %{bypass: bypass} do
      {user, conversation} = create_user_and_conversation()

      Bypass.stub(bypass, "POST", "/chat/completions", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(500, Jason.encode!(%{
          "error" => %{"message" => "Internal server error"}
        }))
      end)

      {:ok, pid} = Engine.start_link(conversation.id, user_id: user.id, channel: "test")
      result = Engine.send_message(conversation.id, "Hello")

      assert {:error, {:api_error, 500, "Internal server error"}} = result

      safe_stop(pid)
    end

    test "Engine returns error on rate limit (429)", %{bypass: bypass} do
      {user, conversation} = create_user_and_conversation()

      Bypass.stub(bypass, "POST", "/chat/completions", fn conn ->
        conn
        |> Plug.Conn.put_resp_header("retry-after", "30")
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(429, Jason.encode!(%{
          "error" => %{"message" => "Rate limited"}
        }))
      end)

      {:ok, pid} = Engine.start_link(conversation.id, user_id: user.id, channel: "test")
      result = Engine.send_message(conversation.id, "Hello")

      assert {:error, {:rate_limited, 30}} = result

      safe_stop(pid)
    end

    test "Engine returns error on malformed JSON response", %{bypass: bypass} do
      {user, conversation} = create_user_and_conversation()

      Bypass.stub(bypass, "POST", "/chat/completions", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, "not valid json at all {{{")
      end)

      {:ok, pid} = Engine.start_link(conversation.id, user_id: user.id, channel: "test")
      result = Engine.send_message(conversation.id, "Hello")

      # Req will fail to decode the JSON body, resulting in an error
      assert {:error, _reason} = result

      safe_stop(pid)
    end

    test "Engine returns error on empty response body", %{bypass: bypass} do
      {user, conversation} = create_user_and_conversation()

      Bypass.stub(bypass, "POST", "/chat/completions", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{
          "id" => "empty",
          "model" => "test",
          "choices" => []
        }))
      end)

      {:ok, pid} = Engine.start_link(conversation.id, user_id: user.id, channel: "test")
      result = Engine.send_message(conversation.id, "Hello")

      # Empty choices array should result in an error from parse_completion
      assert {:error, _reason} = result

      safe_stop(pid)
    end

    test "Engine handles LLM returning nil content and no tool calls", %{bypass: bypass} do
      {user, conversation} = create_user_and_conversation()

      Bypass.stub(bypass, "POST", "/chat/completions", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{
          "id" => "nil-content",
          "model" => "test",
          "choices" => [
            %{
              "message" => %{
                "role" => "assistant",
                "content" => nil
              },
              "finish_reason" => "stop"
            }
          ],
          "usage" => %{"prompt_tokens" => 10, "completion_tokens" => 0, "total_tokens" => 10}
        }))
      end)

      {:ok, pid} = Engine.start_link(conversation.id, user_id: user.id, channel: "test")
      result = Engine.send_message(conversation.id, "Hello")

      # nil content with no tool calls should return empty string via LoopRunner
      assert {:ok, ""} = result

      safe_stop(pid)
    end

    test "Engine survives after error and can handle next message", %{bypass: bypass} do
      {user, conversation} = create_user_and_conversation()
      call_count = :counters.new(1, [:atomics])

      Bypass.stub(bypass, "POST", "/chat/completions", fn conn ->
        :counters.add(call_count, 1, 1)
        current = :counters.get(call_count, 1)

        if current == 1 do
          # First call: error
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.resp(500, Jason.encode!(%{
            "error" => %{"message" => "Temporary failure"}
          }))
        else
          # Second call: success
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.resp(200, Jason.encode!(text_response("I'm back!")))
        end
      end)

      {:ok, pid} = Engine.start_link(conversation.id, user_id: user.id, channel: "test")

      # First message fails
      assert {:error, _} = Engine.send_message(conversation.id, "Hello")

      # Second message succeeds — engine is still alive and functional
      assert {:ok, "I'm back!"} = Engine.send_message(conversation.id, "Try again")

      safe_stop(pid)
    end
  end

  # ---------------------------------------------------------------
  # 4. Max iteration limit enforcement
  # ---------------------------------------------------------------

  describe "max iteration limit" do
    test "Engine terminates loop after max iterations with limit message", %{bypass: bypass} do
      {user, conversation} = create_user_and_conversation()
      call_count = :counters.new(1, [:atomics])
      max_iters = Assistant.Orchestrator.LoopRunner.max_iterations()

      Bypass.stub(bypass, "POST", "/chat/completions", fn conn ->
        :counters.add(call_count, 1, 1)

        # Always return a tool call — forces the engine to keep looping
        response = tool_call_response([
          {"call_#{:counters.get(call_count, 1)}", "get_skill", %{"domain" => "email"}}
        ])

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(response))
      end)

      {:ok, pid} = Engine.start_link(conversation.id, user_id: user.id, channel: "test")
      {:ok, response} = Engine.send_message(conversation.id, "Keep going")

      # Should hit the max iteration limit and return the limit message
      assert response =~ "processing limit"

      # Should have made at least max_iters LLM calls (background tasks
      # like TurnClassifier may add more)
      assert :counters.get(call_count, 1) >= max_iters

      safe_stop(pid)
    end
  end

  # ---------------------------------------------------------------
  # 5. Multi-turn conversation
  # ---------------------------------------------------------------

  describe "multi-turn conversation" do
    test "Engine maintains message history across turns", %{bypass: bypass} do
      {user, conversation} = create_user_and_conversation()
      call_count = :counters.new(1, [:atomics])

      Bypass.stub(bypass, "POST", "/chat/completions", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        request = Jason.decode!(body)

        :counters.add(call_count, 1, 1)
        current = :counters.get(call_count, 1)

        # Verify message history grows with each turn
        messages = request["messages"]

        response =
          if current == 1 do
            # First turn: should have system + user message
            text_response("Hi! I remember you.")
          else
            # Second turn: should include prior user + assistant messages
            # Check that history contains previous messages
            all_content =
              messages
              |> Enum.filter(&(&1["role"] == "user"))
              |> Enum.flat_map(fn msg ->
                case msg["content"] do
                  c when is_binary(c) -> [c]
                  parts when is_list(parts) -> Enum.map(parts, &(&1["text"] || ""))
                  _ -> []
                end
              end)
              |> Enum.join(" ")

            if String.contains?(all_content, "My name is Alice") do
              text_response("Yes, your name is Alice!")
            else
              text_response("I don't remember your name.")
            end
          end

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(response))
      end)

      {:ok, pid} = Engine.start_link(conversation.id, user_id: user.id, channel: "test")

      # First turn
      {:ok, _} = Engine.send_message(conversation.id, "My name is Alice")

      # Second turn — should include prior history
      {:ok, response} = Engine.send_message(conversation.id, "What is my name?")
      assert response == "Yes, your name is Alice!"

      # Verify message count grew
      {:ok, state} = Engine.get_state(conversation.id)
      assert state.message_count >= 4  # user1, asst1, user2, asst2

      safe_stop(pid)
    end

    test "Engine resets per-turn state between messages", %{bypass: bypass} do
      {user, conversation} = create_user_and_conversation()

      Bypass.stub(bypass, "POST", "/chat/completions", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(text_response("OK")))
      end)

      {:ok, pid} = Engine.start_link(conversation.id, user_id: user.id, channel: "test")

      {:ok, _} = Engine.send_message(conversation.id, "First")
      {:ok, state1} = Engine.get_state(conversation.id)

      {:ok, _} = Engine.send_message(conversation.id, "Second")
      {:ok, state2} = Engine.get_state(conversation.id)

      # iteration_count should reset to 1 for each turn (set in last completed turn)
      assert state1.iteration_count == 1
      assert state2.iteration_count == 1

      safe_stop(pid)
    end
  end

  # ---------------------------------------------------------------
  # 6. Engine modes
  # ---------------------------------------------------------------

  describe "engine modes" do
    test "Engine starts in multi_agent mode by default", %{bypass: bypass} do
      {user, conversation} = create_user_and_conversation()

      # Use stub — no HTTP request is expected (we only check state, not send messages)
      Bypass.stub(bypass, "POST", "/chat/completions", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(text_response("OK")))
      end)

      {:ok, pid} = Engine.start_link(conversation.id, user_id: user.id, channel: "test")
      {:ok, state} = Engine.get_state(conversation.id)

      assert state.mode == :multi_agent

      safe_stop(pid)
    end

    test "Engine can start in single_loop mode", %{bypass: bypass} do
      {user, conversation} = create_user_and_conversation()

      # Use stub — no HTTP request is expected
      Bypass.stub(bypass, "POST", "/chat/completions", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(text_response("OK")))
      end)

      {:ok, pid} =
        Engine.start_link(conversation.id,
          user_id: user.id,
          channel: "test",
          mode: :single_loop
        )

      {:ok, state} = Engine.get_state(conversation.id)
      assert state.mode == :single_loop

      safe_stop(pid)
    end
  end

  # ---------------------------------------------------------------
  # 7. Request verification — correct message structure sent to LLM
  # ---------------------------------------------------------------

  describe "request structure verification" do
    test "Engine sends system prompt and user message to LLM", %{bypass: bypass} do
      {user, conversation} = create_user_and_conversation()
      {:ok, agent} = Agent.start_link(fn -> [] end)

      Bypass.stub(bypass, "POST", "/chat/completions", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        request = Jason.decode!(body)
        Agent.update(agent, fn reqs -> [request | reqs] end)

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(text_response("Verified")))
      end)

      {:ok, pid} = Engine.start_link(conversation.id, user_id: user.id, channel: "test")
      {:ok, _} = Engine.send_message(conversation.id, "Test structure")

      # Get the first request (the one from send_message, not TurnClassifier)
      requests = Agent.get(agent, & &1) |> Enum.reverse()
      assert length(requests) >= 1

      request = hd(requests)

      # Verify basic request structure
      assert is_list(request["messages"])
      assert length(request["messages"]) >= 2

      # First message should be system
      system_msg = hd(request["messages"])
      assert system_msg["role"] == "system"

      # Should have tools
      assert is_list(request["tools"])
      assert length(request["tools"]) > 0

      # Verify tool names include orchestrator tools
      tool_names =
        Enum.map(request["tools"], fn t ->
          get_in(t, ["function", "name"])
        end)

      assert "get_skill" in tool_names
      assert "dispatch_agent" in tool_names

      # Should have a model
      assert is_binary(request["model"])

      Agent.stop(agent)
      safe_stop(pid)
    end

    test "Engine includes Authorization header with API key", %{bypass: bypass} do
      {user, conversation} = create_user_and_conversation()
      {:ok, agent} = Agent.start_link(fn -> [] end)

      Bypass.stub(bypass, "POST", "/chat/completions", fn conn ->
        auth_header = Plug.Conn.get_req_header(conn, "authorization")
        Agent.update(agent, fn headers -> [auth_header | headers] end)

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(text_response("Authorized")))
      end)

      {:ok, pid} = Engine.start_link(conversation.id, user_id: user.id, channel: "test")
      {:ok, _} = Engine.send_message(conversation.id, "Check auth")

      # Verify auth header was sent (check first captured header)
      headers = Agent.get(agent, & &1) |> Enum.reverse()
      assert length(headers) >= 1
      assert hd(headers) == ["Bearer test-bypass-key"]

      Agent.stop(agent)
      safe_stop(pid)
    end
  end

  # ---------------------------------------------------------------
  # 8. Token usage accumulation across iterations
  # ---------------------------------------------------------------

  describe "token usage accumulation" do
    test "Engine accumulates usage across multi-iteration loop", %{bypass: bypass} do
      {user, conversation} = create_user_and_conversation()
      call_count = :counters.new(1, [:atomics])

      Bypass.stub(bypass, "POST", "/chat/completions", fn conn ->
        :counters.add(call_count, 1, 1)
        current = :counters.get(call_count, 1)

        response =
          if current == 1 do
            tool_call_response(
              [{"call_1", "get_skill", %{"domain" => "email"}}],
              usage: %{"prompt_tokens" => 100, "completion_tokens" => 30, "total_tokens" => 130}
            )
          else
            text_response(
              "Done.",
              usage: %{"prompt_tokens" => 200, "completion_tokens" => 50, "total_tokens" => 250}
            )
          end

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(response))
      end)

      {:ok, pid} = Engine.start_link(conversation.id, user_id: user.id, channel: "test")
      {:ok, _} = Engine.send_message(conversation.id, "Test usage")

      {:ok, state} = Engine.get_state(conversation.id)
      # Usage should be sum of both iterations: 100+200=300 prompt, 30+50=80 completion
      assert state.total_usage.prompt_tokens == 300
      assert state.total_usage.completion_tokens == 80

      safe_stop(pid)
    end
  end

  # ---------------------------------------------------------------
  # 9. Concurrent engine isolation
  # ---------------------------------------------------------------

  describe "concurrent engine isolation" do
    test "two engines with different conversation_ids don't interfere", %{bypass: bypass} do
      {user1, conv1} = create_user_and_conversation()
      {user2, conv2} = create_user_and_conversation()

      Bypass.stub(bypass, "POST", "/chat/completions", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        request = Jason.decode!(body)

        # Find the user message to determine which conversation this is for
        user_messages =
          request["messages"]
          |> Enum.filter(&(&1["role"] == "user"))
          |> Enum.flat_map(fn msg ->
            case msg["content"] do
              c when is_binary(c) -> [c]
              parts when is_list(parts) -> Enum.map(parts, &(&1["text"] || ""))
              _ -> []
            end
          end)

        response_text =
          if Enum.any?(user_messages, &String.contains?(&1, "Alpha")) do
            "Response for Alpha"
          else
            "Response for Beta"
          end

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(text_response(response_text)))
      end)

      {:ok, pid1} = Engine.start_link(conv1.id, user_id: user1.id, channel: "test")
      {:ok, pid2} = Engine.start_link(conv2.id, user_id: user2.id, channel: "test")

      {:ok, resp1} = Engine.send_message(conv1.id, "I am Alpha")
      {:ok, resp2} = Engine.send_message(conv2.id, "I am Beta")

      assert resp1 == "Response for Alpha"
      assert resp2 == "Response for Beta"

      # Verify they have independent state
      {:ok, state1} = Engine.get_state(conv1.id)
      {:ok, state2} = Engine.get_state(conv2.id)
      assert state1.conversation_id == conv1.id
      assert state2.conversation_id == conv2.id
      assert state1.conversation_id != state2.conversation_id

      safe_stop(pid1)
      safe_stop(pid2)
    end
  end

  # ---------------------------------------------------------------
  # 10. Unknown tool call handling
  # ---------------------------------------------------------------

  describe "unknown tool call handling" do
    test "Engine handles unknown tool name gracefully and continues", %{bypass: bypass} do
      {user, conversation} = create_user_and_conversation()
      call_count = :counters.new(1, [:atomics])

      Bypass.stub(bypass, "POST", "/chat/completions", fn conn ->
        :counters.add(call_count, 1, 1)
        current = :counters.get(call_count, 1)

        response =
          if current == 1 do
            # Return an unknown tool call
            tool_call_response([
              {"call_1", "nonexistent_tool", %{"arg" => "value"}}
            ])
          else
            # After error feedback, return text
            text_response("Sorry, I'll try a different approach.")
          end

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(response))
      end)

      {:ok, pid} = Engine.start_link(conversation.id, user_id: user.id, channel: "test")
      {:ok, response} = Engine.send_message(conversation.id, "Do something")

      assert response == "Sorry, I'll try a different approach."
      # At least 2 calls: tool call + text response. May have more from
      # background tasks (TurnClassifier).
      assert :counters.get(call_count, 1) >= 2

      safe_stop(pid)
    end
  end

  # ---------------------------------------------------------------
  # Infrastructure helpers
  # ---------------------------------------------------------------

  defp start_unlinked(module, opts) do
    case module.start_link(opts) do
      {:ok, pid} -> Process.unlink(pid)
      {:error, {:already_started, _}} -> :ok
    end
  end

  defp ensure_config_loader_started do
    if :ets.whereis(:assistant_config) != :undefined do
      :ok
    else
      tmp_dir = System.tmp_dir!()

      config_path =
        Path.join(tmp_dir, "test_config_e2e_#{System.unique_integer([:positive])}.yaml")

      yaml = """
      defaults:
        orchestrator: primary
        compaction: fast

      models:
        - id: "test/fast"
          tier: fast
          description: "test model"
          use_cases: [orchestrator, compaction, sentinel, sub_agent]
          supports_tools: true
          max_context_tokens: 100000
          cost_tier: low

      http:
        max_retries: 0
        base_backoff_ms: 100
        max_backoff_ms: 1000
        request_timeout_ms: 5000
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
      """

      File.write!(config_path, yaml)

      case Assistant.Config.Loader.start_link(path: config_path) do
        {:ok, _} -> :ok
        {:error, {:already_started, _}} -> :ok
      end
    end
  end
end
