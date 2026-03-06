unless Code.ensure_loaded?(Assistant.TestSupport.Orchestrator.BlockingSkill) do
  Code.require_file("../support/orchestrator/blocking_skill.ex", __DIR__)
end

defmodule Assistant.Orchestrator.SubAgentRuntimeToolsTest do
  use ExUnit.Case, async: false

  import Mox

  alias Assistant.Orchestrator.SubAgent
  alias Assistant.Orchestrator.Tools.{CancelAgent, QuerySubagent}

  setup :verify_on_exit!

  setup do
    Process.flag(:trap_exit, true)

    start_unlinked(Registry, keys: :unique, name: Assistant.SubAgent.Registry)
    start_unlinked(Task.Supervisor, name: Assistant.Skills.TaskSupervisor)

    ensure_skills_registry_started()
    ensure_prompt_loader_started()
    ensure_config_loader_started()

    bypass = Bypass.open()

    original_base_url = Application.get_env(:assistant, :openrouter_base_url)
    original_api_key = Application.get_env(:assistant, :openrouter_api_key)

    Application.put_env(:assistant, :openrouter_base_url, "http://localhost:#{bypass.port}")
    Application.put_env(:assistant, :openrouter_api_key, "test-bypass-key")

    on_exit(fn ->
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

    :ok = stub_sentinel_approve()

    %{bypass: bypass}
  end

  test "query_subagent reads a live running snapshot without interrupting the target", %{
    bypass: bypass
  } do
    parent = self()
    blocking_skill_path = install_blocking_test_skill()
    Application.put_env(:assistant, :blocking_skill_notify_pid, parent)

    on_exit(fn ->
      Application.delete_env(:assistant, :blocking_skill_notify_pid)
      remove_blocking_test_skill(blocking_skill_path)
    end)

    {:ok, llm_calls} = Agent.start_link(fn -> 0 end)

    Bypass.stub(bypass, "POST", "/chat/completions", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)

      response =
        if subagent_query_request?(request) do
          send(parent, {:subagent_query_prompt, subagent_query_prompt(request)})

          text_response(
            Jason.encode!(%{
              summary: "The worker is mid-flight.",
              answer: "It is currently blocked inside the test skill and has not finished.",
              progress: "Running",
              blockers: [],
              open_questions: []
            })
          )
        else
          call_number =
            Agent.get_and_update(llm_calls, fn current ->
              next = current + 1
              {next, next}
            end)

          case call_number do
            1 ->
              tool_call_response([
                {"sa_call_1", "use_skill",
                 %{
                   "skill" => "agents.blocking_wait_test",
                   "arguments" => %{}
                 }}
              ])

            _ ->
              text_response("Worker completed after release.")
          end
        end

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(response))
    end)

    dispatch_params = %{
      agent_id: "worker",
      mission: "Investigate the task and report what you find.",
      skills: ["agents.blocking_wait_test"],
      context: nil,
      context_files: []
    }

    {:ok, pid} =
      SubAgent.start_link(
        dispatch_params: dispatch_params,
        dep_results: %{},
        engine_state: %{conversation_id: Ecto.UUID.generate(), user_id: nil}
      )

    ref = Process.monitor(pid)

    assert_receive {:blocking_skill_started, blocking_skill_pid, "worker"}, 2_000

    {:ok, query_result} =
      QuerySubagent.execute(
        %{"agent_id" => "worker", "question" => "What has the agent done so far?"},
        %{user_id: nil, dispatched_agents: %{}}
      )

    assert query_result.status == :ok
    assert query_result.content =~ "Summary:"
    assert query_result.content =~ "Progress: Running"

    assert_receive {:subagent_query_prompt, prompt}, 2_000
    assert prompt =~ "Target agent id: worker"
    assert prompt =~ "Status: running"

    send(blocking_skill_pid, :release)

    assert_receive {:DOWN, ^ref, :process, ^pid, {:shutdown, result_map}}, 5_000
    assert result_map.status == :completed

    Agent.stop(llm_calls)
  end

  test "cancel_agent hard-stops a running sub-agent and returns cancelled terminal state", %{
    bypass: bypass
  } do
    parent = self()
    blocking_skill_path = install_blocking_test_skill()
    Application.put_env(:assistant, :blocking_skill_notify_pid, parent)

    on_exit(fn ->
      Application.delete_env(:assistant, :blocking_skill_notify_pid)
      remove_blocking_test_skill(blocking_skill_path)
    end)

    Bypass.stub(bypass, "POST", "/chat/completions", fn conn ->
      response =
        tool_call_response([
          {"sa_call_1", "use_skill",
           %{
             "skill" => "agents.blocking_wait_test",
             "arguments" => %{}
           }}
        ])

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(response))
    end)

    dispatch_params = %{
      agent_id: "worker",
      mission: "Investigate the task and keep going until told otherwise.",
      skills: ["agents.blocking_wait_test"],
      context: nil,
      context_files: []
    }

    {:ok, pid} =
      SubAgent.start_link(
        dispatch_params: dispatch_params,
        dep_results: %{},
        engine_state: %{conversation_id: Ecto.UUID.generate(), user_id: nil}
      )

    ref = Process.monitor(pid)

    assert_receive {:blocking_skill_started, blocking_skill_pid, "worker"}, 2_000

    {:ok, cancel_result} =
      CancelAgent.execute(%{"agent_id" => "worker", "reason" => "Off rails"}, nil)

    assert cancel_result.status == :ok
    assert cancel_result.content =~ "cancelled immediately"

    send(blocking_skill_pid, :release)

    assert_receive {:DOWN, ^ref, :process, ^pid, {:shutdown, result_map}}, 5_000
    assert result_map.status == :cancelled
    assert result_map.cancel_reason == "Off rails"
    assert result_map.result =~ "Off rails"
  end

  defp stub_sentinel_approve do
    Mox.set_mox_global(self())

    stub(MockLLMRouter, :chat_completion, fn _messages, _opts, _user_id ->
      {:ok,
       %{
         content: ~s({"reasoning":"aligned","decision":"approve","reason":"test approval"})
       }}
    end)

    :ok
  end

  defp text_response(content) do
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
      "usage" => %{
        "prompt_tokens" => 100,
        "completion_tokens" => 50,
        "total_tokens" => 150
      }
    }
  end

  defp tool_call_response(tool_calls) do
    formatted_calls =
      Enum.map(tool_calls, fn {id, name, args} ->
        %{
          "id" => id,
          "type" => "function",
          "function" => %{
            "name" => name,
            "arguments" => Jason.encode!(args)
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
      "usage" => %{
        "prompt_tokens" => 100,
        "completion_tokens" => 50,
        "total_tokens" => 150
      }
    }
  end

  defp subagent_query_request?(request) do
    request
    |> Map.get("messages", [])
    |> List.first()
    |> case do
      %{"content" => content} -> content_text(content) =~ "another sub-agent's progress"
      _ -> false
    end
  end

  defp subagent_query_prompt(request) do
    request
    |> Map.get("messages", [])
    |> Enum.at(1, %{})
    |> Map.get("content", "")
    |> content_text()
  end

  defp content_text(content) when is_binary(content), do: content

  defp content_text(content) when is_list(content) do
    Enum.map_join(content, "\n", fn
      %{"text" => text} when is_binary(text) -> text
      %{text: text} when is_binary(text) -> text
      _ -> ""
    end)
  end

  defp content_text(_), do: ""

  defp install_blocking_test_skill do
    path = Path.join(File.cwd!(), "priv/skills/agents/blocking_wait_test.md")

    File.write!(path, """
    ---
    name: "agents.blocking_wait_test"
    description: "Test-only blocking skill for sub-agent runtime coverage."
    handler: "Assistant.TestSupport.Orchestrator.BlockingSkill"
    tags:
      - agents
      - test
    parameters: []
    ---

    # agents.blocking_wait_test

    Test-only skill that blocks until the test process releases it.
    """)

    Assistant.Skills.Registry.reload_skill(path)
    path
  end

  defp remove_blocking_test_skill(path) do
    Assistant.Skills.Registry.remove_skill(path)
    File.rm(path)
  end

  defp start_unlinked(module, opts) do
    case module.start_link(opts) do
      {:ok, pid} -> Process.unlink(pid)
      {:error, {:already_started, _}} -> :ok
    end
  end

  defp ensure_skills_registry_started do
    if :ets.whereis(:assistant_skills) != :undefined do
      :ok
    else
      start_unlinked(Assistant.Skills.Registry, skills_dir: Path.join(File.cwd!(), "priv/skills"))
    end
  end

  defp ensure_prompt_loader_started do
    if :ets.whereis(:assistant_prompts) != :undefined do
      :ok
    else
      start_unlinked(Assistant.Config.PromptLoader,
        dir: Path.join(File.cwd!(), "priv/config/prompts")
      )
    end
  end

  defp ensure_config_loader_started do
    if :ets.whereis(:assistant_config) != :undefined do
      :ok
    else
      start_unlinked(Assistant.Config.Loader,
        path: Path.join(File.cwd!(), "priv/config/config.yaml")
      )
    end
  end
end
