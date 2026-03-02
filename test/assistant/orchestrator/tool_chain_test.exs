# test/assistant/orchestrator/tool_chain_test.exs
#
# Tests for tool use chain mechanics — format_tool_results edge cases,
# format_assistant_tool_calls variations, tool result content handling,
# and SkillResult.truncate_content behavior.
#
# These tests cover the message-building layer that connects tool call
# responses back into the LLM conversation loop. Unlike the basic tests
# in loop_runner_test.exs, these focus on edge cases, error conditions,
# and realistic multi-step tool chain scenarios.

defmodule Assistant.Orchestrator.ToolChainTest do
  use ExUnit.Case, async: true

  alias Assistant.Orchestrator.LoopRunner
  alias Assistant.Skills.Result, as: SkillResult

  # ---------------------------------------------------------------
  # format_tool_results/1 — edge cases and error payloads
  # ---------------------------------------------------------------

  describe "format_tool_results/1 with error results" do
    test "formats error status results as tool messages" do
      tc = %{id: "call_1", type: "function", function: %{name: "use_skill", arguments: "{}"}}
      result = %SkillResult{status: :error, content: "Skill \"email.send\" not found in registry."}

      [msg] = LoopRunner.format_tool_results([{tc, result}])

      assert msg.role == "tool"
      assert msg.tool_call_id == "call_1"
      assert msg.content =~ "not found in registry"
    end

    test "formats nil content as nil" do
      tc = %{id: "call_1", type: "function", function: %{name: "get_skill", arguments: "{}"}}
      result = %SkillResult{status: :ok, content: nil}

      [msg] = LoopRunner.format_tool_results([{tc, result}])

      assert msg.role == "tool"
      assert msg.tool_call_id == "call_1"
      assert msg.content == nil
    end

    test "formats empty string content" do
      tc = %{id: "call_1", type: "function", function: %{name: "get_skill", arguments: "{}"}}
      result = %SkillResult{status: :ok, content: ""}

      [msg] = LoopRunner.format_tool_results([{tc, result}])

      assert msg.content == ""
    end

    test "truncates large content via SkillResult.truncate_content" do
      # Generate content much larger than 100_000 characters
      large_content = String.duplicate("x", 200_000)

      tc = %{id: "call_1", type: "function", function: %{name: "use_skill", arguments: "{}"}}
      result = %SkillResult{status: :ok, content: large_content}

      [msg] = LoopRunner.format_tool_results([{tc, result}])

      assert msg.role == "tool"
      # Content should be truncated — the base is 100_000 chars + truncation marker
      assert byte_size(msg.content) < byte_size(large_content)
      assert msg.content =~ "[Truncated"
    end
  end

  describe "format_tool_results/1 with mixed results" do
    test "handles mix of success and error results preserving order" do
      tc1 = %{id: "call_1", type: "function", function: %{name: "get_skill", arguments: "{}"}}
      tc2 = %{id: "call_2", type: "function", function: %{name: "use_skill", arguments: "{}"}}
      tc3 = %{id: "call_3", type: "function", function: %{name: "get_skill", arguments: "{}"}}

      r1 = %SkillResult{status: :ok, content: "Found 3 domains"}
      r2 = %SkillResult{status: :error, content: "Skill not found"}
      r3 = %SkillResult{status: :ok, content: "Email domain: 5 skills"}

      messages = LoopRunner.format_tool_results([{tc1, r1}, {tc2, r2}, {tc3, r3}])

      assert length(messages) == 3

      assert Enum.at(messages, 0).tool_call_id == "call_1"
      assert Enum.at(messages, 0).content == "Found 3 domains"

      assert Enum.at(messages, 1).tool_call_id == "call_2"
      assert Enum.at(messages, 1).content =~ "not found"

      assert Enum.at(messages, 2).tool_call_id == "call_3"
      assert Enum.at(messages, 2).content == "Email domain: 5 skills"
    end

    test "handles large number of tool results" do
      pairs =
        for i <- 1..20 do
          tc = %{id: "call_#{i}", type: "function", function: %{name: "get_skill", arguments: "{}"}}
          result = %SkillResult{status: :ok, content: "Result #{i}"}
          {tc, result}
        end

      messages = LoopRunner.format_tool_results(pairs)

      assert length(messages) == 20
      assert Enum.at(messages, 0).tool_call_id == "call_1"
      assert Enum.at(messages, 19).tool_call_id == "call_20"
      assert Enum.at(messages, 19).content == "Result 20"
    end
  end

  # ---------------------------------------------------------------
  # format_assistant_tool_calls/1 — variations
  # ---------------------------------------------------------------

  describe "format_assistant_tool_calls/1 with realistic tool calls" do
    test "preserves full tool call structure including arguments" do
      tool_calls = [
        %{
          id: "call_abc",
          type: "function",
          function: %{
            name: "use_skill",
            arguments: Jason.encode!(%{"skill" => "email.search", "arguments" => %{"query" => "from:alice"}})
          }
        }
      ]

      msg = LoopRunner.format_assistant_tool_calls(tool_calls)

      assert msg.role == "assistant"
      assert length(msg.tool_calls) == 1
      [tc] = msg.tool_calls
      assert tc.id == "call_abc"
      assert tc.function.name == "use_skill"
      assert is_binary(tc.function.arguments)
    end

    test "handles parallel tool calls (multiple get_skill + dispatch)" do
      tool_calls = [
        %{id: "call_1", type: "function", function: %{name: "get_skill", arguments: ~s({"skill_or_domain": "email"})}},
        %{id: "call_2", type: "function", function: %{name: "get_skill", arguments: ~s({"skill_or_domain": "calendar"})}},
        %{id: "call_3", type: "function", function: %{name: "dispatch_agent", arguments: ~s({"agent_id": "search_agent"})}}
      ]

      msg = LoopRunner.format_assistant_tool_calls(tool_calls)

      assert msg.role == "assistant"
      assert length(msg.tool_calls) == 3

      names = Enum.map(msg.tool_calls, & &1.function.name)
      assert "get_skill" in names
      assert "dispatch_agent" in names
    end

    test "handles string-keyed tool calls" do
      tool_calls = [
        %{
          "id" => "call_str",
          "type" => "function",
          "function" => %{"name" => "get_skill", "arguments" => "{}"}
        }
      ]

      msg = LoopRunner.format_assistant_tool_calls(tool_calls)

      assert msg.role == "assistant"
      assert length(msg.tool_calls) == 1
    end

    test "single tool call produces valid assistant message" do
      tool_calls = [
        %{id: "call_1", type: "function", function: %{name: "get_agent_results", arguments: ~s({"agent_ids": ["agent1"]})}}
      ]

      msg = LoopRunner.format_assistant_tool_calls(tool_calls)

      assert msg.role == "assistant"
      assert is_list(msg.tool_calls)
      assert hd(msg.tool_calls).function.name == "get_agent_results"
    end
  end

  # ---------------------------------------------------------------
  # Multi-step tool chain message construction
  # ---------------------------------------------------------------

  describe "multi-step tool chain message construction" do
    test "builds correct conversation history for get_skill → dispatch_agent chain" do
      # Step 1: LLM calls get_skill
      step1_tool_calls = [
        %{id: "call_1", type: "function", function: %{name: "get_skill", arguments: ~s({"skill_or_domain": "email"})}}
      ]

      assistant_msg_1 = LoopRunner.format_assistant_tool_calls(step1_tool_calls)

      step1_result = %SkillResult{status: :ok, content: "email domain: search, read, send, draft, list"}
      tool_result_msgs_1 = LoopRunner.format_tool_results([{hd(step1_tool_calls), step1_result}])

      # Step 2: LLM calls dispatch_agent based on get_skill result
      step2_tool_calls = [
        %{
          id: "call_2",
          type: "function",
          function: %{
            name: "dispatch_agent",
            arguments: Jason.encode!(%{
              "agent_id" => "email_searcher",
              "mission" => "Search for emails from Alice",
              "skills" => ["email.search", "email.read"]
            })
          }
        }
      ]

      assistant_msg_2 = LoopRunner.format_assistant_tool_calls(step2_tool_calls)

      step2_result = %SkillResult{
        status: :ok,
        content: "Agent \"email_searcher\" dispatched with skills: email.search, email.read",
        metadata: %{dispatch: %{agent_id: "email_searcher"}}
      }

      tool_result_msgs_2 = LoopRunner.format_tool_results([{hd(step2_tool_calls), step2_result}])

      # Verify the full conversation history structure
      full_history = [
        %{role: "system", content: "You are an orchestrator."},
        %{role: "user", content: "Find Alice's emails"},
        assistant_msg_1,
        hd(tool_result_msgs_1),
        assistant_msg_2,
        hd(tool_result_msgs_2)
      ]

      # Verify message roles alternate correctly
      roles = Enum.map(full_history, & &1.role)
      assert roles == ["system", "user", "assistant", "tool", "assistant", "tool"]

      # Verify tool_call_ids match between assistant tool_calls and tool results
      assert assistant_msg_1.tool_calls |> hd() |> Map.get(:id) == hd(tool_result_msgs_1).tool_call_id
      assert assistant_msg_2.tool_calls |> hd() |> Map.get(:id) == hd(tool_result_msgs_2).tool_call_id
    end

    test "builds correct history for parallel tool calls in one step" do
      # LLM calls multiple tools at once
      tool_calls = [
        %{id: "call_a", type: "function", function: %{name: "get_skill", arguments: ~s({"skill_or_domain": "email"})}},
        %{id: "call_b", type: "function", function: %{name: "get_skill", arguments: ~s({"skill_or_domain": "calendar"})}}
      ]

      assistant_msg = LoopRunner.format_assistant_tool_calls(tool_calls)

      results = [
        {Enum.at(tool_calls, 0), %SkillResult{status: :ok, content: "email: search, read, send"}},
        {Enum.at(tool_calls, 1), %SkillResult{status: :ok, content: "calendar: list, create, update"}}
      ]

      tool_msgs = LoopRunner.format_tool_results(results)

      # One assistant message with 2 tool_calls, followed by 2 tool result messages
      assert length(assistant_msg.tool_calls) == 2
      assert length(tool_msgs) == 2

      # tool_call_ids correspond
      assert Enum.at(tool_msgs, 0).tool_call_id == "call_a"
      assert Enum.at(tool_msgs, 1).tool_call_id == "call_b"
    end

    test "builds correct history for error mid-chain" do
      # Step 1: get_skill succeeds
      tc1 = %{id: "call_1", type: "function", function: %{name: "get_skill", arguments: ~s({})}}
      r1 = %SkillResult{status: :ok, content: "3 domains available"}

      # Step 2: dispatch_agent fails (unknown skill)
      tc2 = %{
        id: "call_2",
        type: "function",
        function: %{
          name: "dispatch_agent",
          arguments: Jason.encode!(%{
            "agent_id" => "bad_agent",
            "mission" => "Do something",
            "skills" => ["nonexistent.skill"]
          })
        }
      }

      r2 = %SkillResult{
        status: :error,
        content: "Unknown skills: nonexistent.skill. Call get_skill to discover available skills."
      }

      # Build messages
      asst_1 = LoopRunner.format_assistant_tool_calls([tc1])
      tool_1 = LoopRunner.format_tool_results([{tc1, r1}])
      asst_2 = LoopRunner.format_assistant_tool_calls([tc2])
      tool_2 = LoopRunner.format_tool_results([{tc2, r2}])

      history = [
        %{role: "system", content: "System"},
        %{role: "user", content: "Query"},
        asst_1,
        hd(tool_1),
        asst_2,
        hd(tool_2)
      ]

      # The error is conveyed as a tool message, not as an exception
      error_msg = Enum.at(history, 5)
      assert error_msg.role == "tool"
      assert error_msg.content =~ "Unknown skills"
      assert error_msg.tool_call_id == "call_2"
    end
  end

  # ---------------------------------------------------------------
  # SkillResult.truncate_content/1
  # ---------------------------------------------------------------

  describe "SkillResult.truncate_content/1" do
    test "returns nil for nil input" do
      assert SkillResult.truncate_content(nil) == nil
    end

    test "returns content unchanged when under limit" do
      content = "Short content"
      assert SkillResult.truncate_content(content) == content
    end

    test "returns content unchanged at exactly 100_000 bytes" do
      content = String.duplicate("a", 100_000)
      assert SkillResult.truncate_content(content) == content
    end

    test "truncates content exceeding 100_000 bytes" do
      content = String.duplicate("b", 100_001)
      truncated = SkillResult.truncate_content(content)

      assert truncated != content
      assert truncated =~ "[Truncated"
      assert truncated =~ "100000 character limit"
    end

    test "truncated content starts with original prefix" do
      content = "PREFIX_" <> String.duplicate("x", 100_000)
      truncated = SkillResult.truncate_content(content)

      assert String.starts_with?(truncated, "PREFIX_")
    end

    test "handles empty string" do
      assert SkillResult.truncate_content("") == ""
    end

    test "handles content just under the limit" do
      content = String.duplicate("c", 99_999)
      assert SkillResult.truncate_content(content) == content
    end

    test "truncation message is informative" do
      content = String.duplicate("d", 200_000)
      truncated = SkillResult.truncate_content(content)

      assert truncated =~ "Truncated"
      assert truncated =~ "character limit"
      assert truncated =~ "more specific filters"
    end
  end

  # ---------------------------------------------------------------
  # Tool call ID correspondence (critical for LLM conversation)
  # ---------------------------------------------------------------

  describe "tool_call_id correspondence" do
    test "format_tool_results preserves tool call IDs exactly" do
      # OpenAI-format IDs can be any string
      ids = ["call_abc123", "toolu_01ABC", "chatcmpl-xyz", "call_with-dashes_and.dots"]

      pairs =
        Enum.map(ids, fn id ->
          tc = %{id: id, type: "function", function: %{name: "get_skill", arguments: "{}"}}
          result = %SkillResult{status: :ok, content: "ok"}
          {tc, result}
        end)

      messages = LoopRunner.format_tool_results(pairs)

      result_ids = Enum.map(messages, & &1.tool_call_id)
      assert result_ids == ids
    end

    test "assistant message preserves tool call IDs" do
      ids = ["call_1", "call_2", "call_3"]

      tool_calls =
        Enum.map(ids, fn id ->
          %{id: id, type: "function", function: %{name: "get_skill", arguments: "{}"}}
        end)

      msg = LoopRunner.format_assistant_tool_calls(tool_calls)
      msg_ids = Enum.map(msg.tool_calls, & &1.id)

      assert msg_ids == ids
    end
  end
end
