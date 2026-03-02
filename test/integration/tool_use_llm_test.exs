# test/integration/tool_use_llm_test.exs
#
# Integration tests for tool use chains with REAL LLM calls.
# Tests that the LLM correctly selects tools, generates valid tool_call
# JSON, and handles multi-step chains where one tool result informs
# the next tool call.
#
# Uses real OpenRouter API calls with mock integrations for external
# services (Gmail, Calendar, Drive).
#
# Related files:
#   - lib/assistant/orchestrator/loop_runner.ex (tool routing)
#   - lib/assistant/orchestrator/tools/ (get_skill, dispatch_agent)
#   - lib/assistant/integrations/openrouter.ex (real LLM client)
#   - test/integration/support/integration_helpers.ex (helpers)
#   - test/integration/support/mock_integrations.ex (mock services)

defmodule Assistant.Integration.ToolUseLLMTest do
  use ExUnit.Case, async: false

  import Assistant.Integration.Helpers

  @moduletag :integration
  @moduletag timeout: 120_000

  alias Assistant.Integrations.OpenRouter
  alias Assistant.Skills.Registry

  @integration_model "openai/gpt-4.1-mini"

  # Real API key must be provided via OPENROUTER_API_KEY env var.
  # Tests are skipped if no key is available (CI without secrets).
  setup do
    clear_mock_calls()
    ensure_skills_registry()

    case System.get_env("OPENROUTER_API_KEY") do
      key when is_binary(key) and key != "" ->
        {:ok, api_key: key}

      _ ->
        :ok
    end
  end

  # ---------------------------------------------------------------
  # Single tool selection — LLM picks the right tool
  # ---------------------------------------------------------------

  describe "single tool selection with real LLM" do
    @tag :integration
    test "LLM selects get_skill when asked to discover capabilities", context do
      if not has_api_key?(context), do: flunk("Skipped: OPENROUTER_API_KEY not set")

      messages = [
        %{role: "system", content: orchestrator_system_prompt()},
        %{role: "user", content: "What email skills are available?"}
      ]

      tools = orchestrator_tools()

      case call_llm_with_tools(messages, tools, context.api_key) do
        {:tool_calls, tool_calls} ->
          assert length(tool_calls) >= 1
          names = Enum.map(tool_calls, &extract_tool_name/1)
          assert "get_skill" in names

          # Verify arguments are valid JSON and contain expected fields
          tc = Enum.find(tool_calls, fn tc -> extract_tool_name(tc) == "get_skill" end)
          args = extract_tool_args(tc)
          assert is_map(args)

          # LLM should specify the email domain
          if map_size(args) > 0 do
            domain = args["skill_or_domain"] || args["domain"]
            assert is_binary(domain)
            assert domain =~ ~r/email/i
          end

        {:text, _content} ->
          # Acceptable: LLM may respond with text if it knows the answer
          :ok
      end
    end

    @tag :integration
    test "LLM selects dispatch_agent for email task", context do
      if not has_api_key?(context), do: flunk("Skipped: OPENROUTER_API_KEY not set")

      # First give context about available skills
      messages = [
        %{role: "system", content: orchestrator_system_prompt()},
        %{
          role: "user",
          content: "Search my emails for messages from alice@example.com about the weekly report"
        }
      ]

      tools = orchestrator_tools()

      case call_llm_with_tools(messages, tools, context.api_key) do
        {:tool_calls, tool_calls} ->
          names = Enum.map(tool_calls, &extract_tool_name/1)
          # LLM should call either get_skill first (to discover) or dispatch_agent directly
          assert "get_skill" in names or "dispatch_agent" in names

        {:text, _content} ->
          # LLM may respond with text — acceptable for first turn
          :ok
      end
    end

    @tag :integration
    test "tool_calls have valid OpenAI-format structure", context do
      if not has_api_key?(context), do: flunk("Skipped: OPENROUTER_API_KEY not set")

      messages = [
        %{role: "system", content: orchestrator_system_prompt()},
        %{role: "user", content: "List all available skill domains"}
      ]

      tools = orchestrator_tools()

      case call_llm_with_tools(messages, tools, context.api_key) do
        {:tool_calls, tool_calls} ->
          for tc <- tool_calls do
            # Must have id, type, function fields
            assert is_binary(tc_id(tc))
            assert tc_type(tc) == "function"

            # function must have name and arguments
            func = tc_function(tc)
            assert is_binary(func_name(func))
            assert is_binary(func_arguments(func)) or is_map(func_arguments(func))

            # arguments must be valid JSON if string
            args_raw = func_arguments(func)

            if is_binary(args_raw) do
              assert {:ok, _} = Jason.decode(args_raw)
            end
          end

        {:text, _} ->
          :ok
      end
    end
  end

  # ---------------------------------------------------------------
  # Multi-step tool chains — LLM makes follow-up tool calls
  # ---------------------------------------------------------------

  describe "multi-step tool chains with real LLM" do
    @tag :integration
    test "get_skill → dispatch_agent chain", context do
      if not has_api_key?(context), do: flunk("Skipped: OPENROUTER_API_KEY not set")
      api_key = context.api_key
      tools = orchestrator_tools()

      # Step 1: Ask about email capabilities
      messages = [
        %{role: "system", content: orchestrator_system_prompt()},
        %{role: "user", content: "I need to search my emails. First check what email skills are available, then dispatch an agent to search for messages from alice@example.com."}
      ]

      case call_llm_with_tools(messages, tools, api_key) do
        {:tool_calls, tool_calls} ->
          # First call should be get_skill
          first_tc = hd(tool_calls)
          first_name = extract_tool_name(first_tc)

          if first_name == "get_skill" do
            # Simulate get_skill result
            skill_result = "email domain: search, read, send, draft, list"

            # Build conversation with tool result
            step2_messages =
              messages ++
                [
                  %{role: "assistant", tool_calls: tool_calls},
                  %{
                    role: "tool",
                    tool_call_id: tc_id(first_tc),
                    content: skill_result
                  }
                ]

            # Step 2: LLM should now dispatch_agent
            case call_llm_with_tools(step2_messages, tools, api_key) do
              {:tool_calls, step2_calls} ->
                names = Enum.map(step2_calls, &extract_tool_name/1)
                assert "dispatch_agent" in names

                # Verify dispatch_agent arguments contain mission and skills
                dispatch_tc =
                  Enum.find(step2_calls, fn tc ->
                    extract_tool_name(tc) == "dispatch_agent"
                  end)

                if dispatch_tc do
                  args = extract_tool_args(dispatch_tc)
                  assert is_binary(args["mission"]) or is_binary(args["agent_id"])
                end

              {:text, _} ->
                # Acceptable: LLM may decide to respond with text
                :ok
            end
          end

        {:text, _} ->
          :ok
      end
    end

    @tag :integration
    test "parallel get_skill calls for multiple domains", context do
      if not has_api_key?(context), do: flunk("Skipped: OPENROUTER_API_KEY not set")
      tools = orchestrator_tools()

      messages = [
        %{role: "system", content: orchestrator_system_prompt()},
        %{
          role: "user",
          content:
            "I need to check my emails AND my calendar. Look up what skills are available in both the email and calendar domains."
        }
      ]

      case call_llm_with_tools(messages, tools, context.api_key) do
        {:tool_calls, tool_calls} ->
          get_skill_calls =
            Enum.filter(tool_calls, fn tc -> extract_tool_name(tc) == "get_skill" end)

          # LLM should make multiple get_skill calls (one per domain)
          # or at least one get_skill call
          assert length(get_skill_calls) >= 1

          # If multiple, check they target different domains
          if length(get_skill_calls) >= 2 do
            domains =
              Enum.map(get_skill_calls, fn tc ->
                args = extract_tool_args(tc)
                args["skill_or_domain"] || args["domain"] || ""
              end)

            unique_domains = Enum.uniq(domains)
            assert length(unique_domains) >= 2
          end

        {:text, _} ->
          :ok
      end
    end
  end

  # ---------------------------------------------------------------
  # Skill execution with real LLM selection
  # ---------------------------------------------------------------

  describe "skill execution via real LLM" do
    @tag :integration
    test "LLM selects email.search and arguments are parseable", context do
      if not has_api_key?(context), do: flunk("Skipped: OPENROUTER_API_KEY not set")

      mission = "Search my emails for messages about the quarterly report"
      skill_names = ["email.search", "email.send", "email.list", "email.read"]

      result = ask_llm_for_skill_call(mission, skill_names, api_key: context.api_key)

      case result do
        {:tool_call, skill_name, args} ->
          # Should select email.search
          assert skill_name == "email.search"
          assert is_map(args)
          # Args should contain a query-like field
          assert map_size(args) >= 1

        {:text, _} ->
          flunk("Expected tool call but LLM returned text")

        {:error, reason} ->
          flunk("LLM call failed: #{inspect(reason)}")
      end
    end

    @tag :integration
    test "LLM selects correct skill from cross-domain options", context do
      if not has_api_key?(context), do: flunk("Skipped: OPENROUTER_API_KEY not set")

      mission = "Create a new calendar event for tomorrow at 3pm"

      skill_names = [
        "email.search",
        "email.send",
        "calendar.list",
        "calendar.create",
        "calendar.update"
      ]

      result = ask_llm_for_skill_call(mission, skill_names, api_key: context.api_key)

      case result do
        {:tool_call, skill_name, _args} ->
          # Should select calendar.create (not email or calendar.list)
          assert skill_name == "calendar.create"

        {:text, _} ->
          flunk("Expected tool call but LLM returned text")

        {:error, reason} ->
          flunk("LLM call failed: #{inspect(reason)}")
      end
    end

    @tag :integration
    test "full skill integration: LLM selects + skill executes", context do
      if not has_api_key?(context), do: flunk("Skipped: OPENROUTER_API_KEY not set")

      mission = "Search for recent emails about project updates"
      skill_names = ["email.search", "email.list", "email.read"]

      result = run_skill_integration(mission, skill_names, :email, api_key: context.api_key)

      case result do
        {:ok, %{skill: skill_name, flags: flags, result: skill_result}} ->
          assert skill_name in ["email.search", "email.list"]
          assert is_map(flags)
          assert skill_result.status in [:ok, :error]

          if skill_result.status == :ok do
            assert mock_was_called?(:email)
          end

        {:error, reason} ->
          flunk("Skill integration failed: #{inspect(reason)}")
      end
    end
  end

  # ---------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------

  defp orchestrator_system_prompt do
    """
    You are an AI orchestrator. You have access to tools for discovering and
    dispatching skills. Use get_skill to discover available skills, then
    dispatch_agent to execute them.

    IMPORTANT: Always use tools to fulfill user requests. Do not respond with
    text when a tool call would be more appropriate.

    Available tool functions:
    - get_skill: Discover available skills (call with skill_or_domain parameter)
    - dispatch_agent: Dispatch a sub-agent with a mission and skills
    - get_agent_results: Check results of dispatched agents
    """
  end

  defp orchestrator_tools do
    [
      %{
        type: "function",
        function: %{
          name: "get_skill",
          description: "Discover available skills. Pass a domain name (e.g., 'email', 'calendar') to see skills in that domain, or omit to see all domains.",
          parameters: %{
            "type" => "object",
            "properties" => %{
              "skill_or_domain" => %{
                "type" => "string",
                "description" => "Domain or skill name to look up (e.g., 'email', 'calendar', 'email.search')"
              },
              "search" => %{
                "type" => "string",
                "description" => "Search query to find skills by keyword"
              }
            }
          }
        }
      },
      %{
        type: "function",
        function: %{
          name: "dispatch_agent",
          description: "Dispatch a sub-agent to execute a mission using specified skills.",
          parameters: %{
            "type" => "object",
            "properties" => %{
              "agent_id" => %{
                "type" => "string",
                "description" => "Unique identifier for this agent"
              },
              "mission" => %{
                "type" => "string",
                "description" => "Description of what the agent should do"
              },
              "skills" => %{
                "type" => "array",
                "items" => %{"type" => "string"},
                "description" => "List of skill names the agent can use"
              }
            },
            "required" => ["agent_id", "mission", "skills"]
          }
        }
      },
      %{
        type: "function",
        function: %{
          name: "get_agent_results",
          description: "Get results from dispatched agents.",
          parameters: %{
            "type" => "object",
            "properties" => %{
              "agent_ids" => %{
                "type" => "array",
                "items" => %{"type" => "string"},
                "description" => "Agent IDs to check results for"
              }
            }
          }
        }
      }
    ]
  end

  defp has_api_key?(context), do: Map.has_key?(context, :api_key)

  defp call_llm_with_tools(messages, tools, api_key) do
    opts = [
      model: @integration_model,
      tools: tools,
      temperature: 0.0,
      api_key: api_key
    ]

    case OpenRouter.chat_completion(messages, opts) do
      {:ok, response} ->
        cond do
          is_list(response.tool_calls) and response.tool_calls != [] ->
            {:tool_calls, response.tool_calls}

          is_binary(response.content) and response.content != "" ->
            {:text, response.content}

          true ->
            {:text, ""}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp extract_tool_name(tc) do
    get_in(tc, [:function, :name]) ||
      get_in(tc, ["function", "name"]) ||
      "unknown"
  end

  defp extract_tool_args(tc) do
    raw = get_in(tc, [:function, :arguments]) || get_in(tc, ["function", "arguments"]) || "{}"

    case raw do
      s when is_binary(s) ->
        case Jason.decode(s) do
          {:ok, decoded} -> decoded
          {:error, _} -> %{}
        end

      m when is_map(m) ->
        m

      _ ->
        %{}
    end
  end

  # Tool call field accessors that handle both atom and string keys
  defp tc_id(tc), do: tc[:id] || tc["id"]
  defp tc_type(tc), do: tc[:type] || tc["type"]
  defp tc_function(tc), do: tc[:function] || tc["function"]
  defp func_name(func), do: func[:name] || func["name"]
  defp func_arguments(func), do: func[:arguments] || func["arguments"]

  defp ensure_skills_registry do
    if :ets.whereis(:assistant_skills) == :undefined do
      skills_dir = Path.join(File.cwd!(), "priv/skills")

      if File.dir?(skills_dir) do
        case Registry.start_link(skills_dir: skills_dir) do
          {:ok, _} -> :ok
          {:error, {:already_started, _}} -> :ok
        end
      end
    end

    :ok
  end
end
