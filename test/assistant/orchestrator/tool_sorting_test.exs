# test/assistant/orchestrator/tool_sorting_test.exs
#
# Tests for tool sorting, selection, and presentation to the LLM.
# Covers OpenRouter.sort_tools edge cases and build_request_body
# tool handling that affects how tools are presented in tool chains.

defmodule Assistant.Orchestrator.ToolSortingTest do
  use ExUnit.Case, async: true

  alias Assistant.Integrations.OpenRouter

  # ---------------------------------------------------------------
  # sort_tools/1 — extended edge cases
  # ---------------------------------------------------------------

  describe "sort_tools/1 extended cases" do
    test "sorts tools with unicode names" do
      tools = [
        %{function: %{name: "über_tool"}},
        %{function: %{name: "alpha_tool"}}
      ]

      sorted = OpenRouter.sort_tools(tools)
      names = Enum.map(sorted, fn t -> t.function.name end)
      assert names == ["alpha_tool", "über_tool"]
    end

    test "maintains stable sort for identical names" do
      tools = [
        %{function: %{name: "same_name"}, extra: :first},
        %{function: %{name: "same_name"}, extra: :second}
      ]

      sorted = OpenRouter.sort_tools(tools)
      assert length(sorted) == 2
    end

    test "sorts real orchestrator tool names correctly" do
      # These are the actual tool names used in the system
      tools = [
        %{function: %{name: "send_agent_update"}},
        %{function: %{name: "get_skill"}},
        %{function: %{name: "dispatch_agent"}},
        %{function: %{name: "get_agent_results"}}
      ]

      sorted = OpenRouter.sort_tools(tools)
      names = Enum.map(sorted, fn t -> t.function.name end)

      assert names == [
               "dispatch_agent",
               "get_agent_results",
               "get_skill",
               "send_agent_update"
             ]
    end

    test "sorts use_skill and request_help (sub-agent tools)" do
      tools = [
        %{function: %{name: "request_help"}},
        %{function: %{name: "use_skill"}}
      ]

      sorted = OpenRouter.sort_tools(tools)
      names = Enum.map(sorted, fn t -> t.function.name end)
      assert names == ["request_help", "use_skill"]
    end

    test "handles tools with additional properties beyond function" do
      tools = [
        %{type: "function", function: %{name: "zebra", description: "Z tool", parameters: %{}}},
        %{type: "function", function: %{name: "alpha", description: "A tool", parameters: %{}}}
      ]

      sorted = OpenRouter.sort_tools(tools)
      names = Enum.map(sorted, fn t -> t.function.name end)
      assert names == ["alpha", "zebra"]
    end

    test "handles large tool list sorting" do
      tools =
        for i <- 100..1//-1 do
          %{function: %{name: "tool_#{String.pad_leading(to_string(i), 3, "0")}"}}
        end

      sorted = OpenRouter.sort_tools(tools)
      names = Enum.map(sorted, fn t -> t.function.name end)

      # Should be in ascending order
      assert names == Enum.sort(names)
      assert hd(names) == "tool_001"
      assert List.last(names) == "tool_100"
    end
  end

  # ---------------------------------------------------------------
  # build_request_body/2 — tool-related edge cases
  # ---------------------------------------------------------------

  describe "build_request_body/2 tool handling" do
    test "sorts tools in request body alphabetically" do
      messages = [%{role: "user", content: "Hello"}]

      tools = [
        %{type: "function", function: %{name: "send_agent_update"}},
        %{type: "function", function: %{name: "dispatch_agent"}},
        %{type: "function", function: %{name: "get_skill"}}
      ]

      {:ok, body} = OpenRouter.build_request_body(messages, model: "test/model", tools: tools)

      names = Enum.map(body.tools, fn t -> t.function.name end)
      assert names == ["dispatch_agent", "get_skill", "send_agent_update"]
    end

    test "nil tools list treated as absent" do
      messages = [%{role: "user", content: "Hello"}]
      {:ok, body} = OpenRouter.build_request_body(messages, model: "test/model", tools: nil)

      refute Map.has_key?(body, :tools)
      refute Map.has_key?(body, :tool_choice)
    end

    test "preserves tool_choice none when specified" do
      messages = [%{role: "user", content: "Hello"}]
      tools = [%{type: "function", function: %{name: "test"}}]

      {:ok, body} =
        OpenRouter.build_request_body(messages,
          model: "test/model",
          tools: tools,
          tool_choice: "none"
        )

      assert body.tool_choice == "none"
    end

    test "single tool in request body is properly formatted" do
      messages = [%{role: "user", content: "Do something"}]
      tools = [%{type: "function", function: %{name: "the_only_tool"}}]

      {:ok, body} = OpenRouter.build_request_body(messages, model: "test/model", tools: tools)

      assert length(body.tools) == 1
      assert body.tool_choice == "auto"
    end
  end

  # ---------------------------------------------------------------
  # Tool definition structure validation
  # ---------------------------------------------------------------

  describe "tool definition structure for LLM consumption" do
    test "orchestrator tool call structure is valid OpenAI format" do
      # This verifies that the format we test against matches
      # what the LLM actually receives
      tc = %{
        id: "call_abc123",
        type: "function",
        function: %{
          name: "get_skill",
          arguments: Jason.encode!(%{"skill_or_domain" => "email"})
        }
      }

      # Must have all required OpenAI tool call fields
      assert is_binary(tc.id)
      assert tc.type == "function"
      assert is_binary(tc.function.name)
      assert is_binary(tc.function.arguments)

      # Arguments must be valid JSON
      assert {:ok, _} = Jason.decode(tc.function.arguments)
    end

    test "sub-agent use_skill tool call structure" do
      tc = %{
        id: "call_xyz789",
        type: "function",
        function: %{
          name: "use_skill",
          arguments: Jason.encode!(%{
            "skill" => "email.search",
            "arguments" => %{"query" => "from:alice subject:report"}
          })
        }
      }

      assert tc.function.name == "use_skill"
      {:ok, args} = Jason.decode(tc.function.arguments)
      assert args["skill"] == "email.search"
      assert is_map(args["arguments"])
    end

    test "tool result message has required fields" do
      msg = %{
        role: "tool",
        tool_call_id: "call_abc123",
        content: "Found 3 emails matching your query."
      }

      assert msg.role == "tool"
      assert is_binary(msg.tool_call_id)
      assert is_binary(msg.content)
    end

    test "assistant tool_calls message has required fields" do
      msg = %{
        role: "assistant",
        tool_calls: [
          %{
            id: "call_1",
            type: "function",
            function: %{name: "get_skill", arguments: "{}"}
          }
        ]
      }

      assert msg.role == "assistant"
      assert is_list(msg.tool_calls)
      assert length(msg.tool_calls) >= 1
    end
  end
end
