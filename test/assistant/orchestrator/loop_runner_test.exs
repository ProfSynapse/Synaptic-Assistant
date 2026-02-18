# test/assistant/orchestrator/loop_runner_test.exs
#
# Tests for the LoopRunner pure-function LLM loop logic.
# Covers public helpers and format functions. run_iteration/3
# is tested indirectly via format functions since it depends on
# a compile-time @llm_client module attribute.

defmodule Assistant.Orchestrator.LoopRunnerTest do
  use ExUnit.Case, async: true

  alias Assistant.Orchestrator.LoopRunner
  alias Assistant.Skills.Result, as: SkillResult

  # ---------------------------------------------------------------
  # max_iterations/0
  # ---------------------------------------------------------------

  describe "max_iterations/0" do
    test "returns a positive integer" do
      max = LoopRunner.max_iterations()
      assert is_integer(max)
      assert max > 0
    end

    test "returns the default value of 10" do
      assert LoopRunner.max_iterations() == 10
    end
  end

  # ---------------------------------------------------------------
  # format_tool_results/1
  # ---------------------------------------------------------------

  describe "format_tool_results/1" do
    test "formats a single tool result as a tool message" do
      tc = %{id: "call_1", type: "function", function: %{name: "get_skill", arguments: "{}"}}
      result = %SkillResult{status: :ok, content: "Found 3 skills."}

      messages = LoopRunner.format_tool_results([{tc, result}])

      assert [msg] = messages
      assert msg.role == "tool"
      assert msg.tool_call_id == "call_1"
      assert msg.content == "Found 3 skills."
    end

    test "formats multiple tool results preserving order" do
      tc1 = %{id: "call_1", type: "function", function: %{name: "get_skill", arguments: "{}"}}
      tc2 = %{id: "call_2", type: "function", function: %{name: "get_skill", arguments: "{}"}}
      r1 = %SkillResult{status: :ok, content: "First result"}
      r2 = %SkillResult{status: :ok, content: "Second result"}

      messages = LoopRunner.format_tool_results([{tc1, r1}, {tc2, r2}])

      assert length(messages) == 2
      assert Enum.at(messages, 0).tool_call_id == "call_1"
      assert Enum.at(messages, 0).content == "First result"
      assert Enum.at(messages, 1).tool_call_id == "call_2"
      assert Enum.at(messages, 1).content == "Second result"
    end

    test "returns empty list for empty input" do
      assert [] = LoopRunner.format_tool_results([])
    end
  end

  # ---------------------------------------------------------------
  # format_assistant_tool_calls/1
  # ---------------------------------------------------------------

  describe "format_assistant_tool_calls/1" do
    test "builds an assistant message with tool calls" do
      tool_calls = [
        %{id: "call_1", type: "function", function: %{name: "get_skill", arguments: "{}"}},
        %{id: "call_2", type: "function", function: %{name: "dispatch_agent", arguments: "{}"}}
      ]

      msg = LoopRunner.format_assistant_tool_calls(tool_calls)

      assert msg.role == "assistant"
      assert length(msg.tool_calls) == 2
      assert Enum.at(msg.tool_calls, 0).id == "call_1"
      assert Enum.at(msg.tool_calls, 1).id == "call_2"
    end

    test "builds assistant message with empty tool calls" do
      msg = LoopRunner.format_assistant_tool_calls([])
      assert msg.role == "assistant"
      assert msg.tool_calls == []
    end
  end

  # Note: run_iteration/3 is not unit-testable without mock infrastructure.
  # It depends on compile-time @llm_client, Skills.Registry ETS, ConfigLoader,
  # PromptLoader, and Context.tool_definitions. These are covered by integration
  # tests when the full application is running.
end
