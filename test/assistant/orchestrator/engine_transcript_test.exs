# test/assistant/orchestrator/engine_transcript_test.exs — Tests for transcript
# serialization functions in Engine.
#
# serialize_transcript/1 and format_transcript_message/1 are pure functions
# that convert the sub-agent's message list into a compact text representation
# for memory storage. They are exposed as @doc false public functions to
# enable direct testing.
#
# Related files:
#   - lib/assistant/orchestrator/engine.ex (functions under test)
#   - lib/assistant/scheduler/workers/memory_save_worker.ex (consumer of serialized output)

defmodule Assistant.Orchestrator.EngineTranscriptTest do
  use ExUnit.Case, async: true

  alias Assistant.Orchestrator.Engine

  # -------------------------------------------------------------------
  # serialize_transcript/1
  # -------------------------------------------------------------------

  describe "serialize_transcript/1" do
    test "returns nil for nil input" do
      assert Engine.serialize_transcript(nil) == nil
    end

    test "returns empty string for empty list" do
      assert Engine.serialize_transcript([]) == ""
    end

    test "serializes a single user message" do
      messages = [%{role: "user", content: "Hello"}]
      result = Engine.serialize_transcript(messages)

      assert result == "[user] Hello"
    end

    test "serializes multiple messages with separator" do
      messages = [
        %{role: "user", content: "What is 2+2?"},
        %{role: "assistant", content: "The answer is 4."}
      ]

      result = Engine.serialize_transcript(messages)

      assert result == "[user] What is 2+2?\n\n---\n\n[assistant] The answer is 4."
    end

    test "strips system messages" do
      messages = [
        %{role: "system", content: "You are an assistant. <long prompt>"},
        %{role: "user", content: "Hello"},
        %{role: "assistant", content: "Hi there!"}
      ]

      result = Engine.serialize_transcript(messages)

      refute result =~ "system"
      refute result =~ "long prompt"
      assert result =~ "[user] Hello"
      assert result =~ "[assistant] Hi there!"
    end

    test "strips multiple system messages" do
      messages = [
        %{role: "system", content: "First system prompt"},
        %{role: "user", content: "Hello"},
        %{role: "system", content: "Second system prompt (injected)"},
        %{role: "assistant", content: "Response"}
      ]

      result = Engine.serialize_transcript(messages)

      refute result =~ "system"
      assert result == "[user] Hello\n\n---\n\n[assistant] Response"
    end

    test "handles tool role messages" do
      messages = [
        %{role: "tool", content: "Skill result: task created successfully"}
      ]

      result = Engine.serialize_transcript(messages)

      assert result == "[tool] Skill result: task created successfully"
    end

    test "handles message with role but no content" do
      messages = [%{role: "assistant"}]

      result = Engine.serialize_transcript(messages)

      assert result == "[assistant]"
    end

    test "serializes a full conversation with tool calls" do
      messages = [
        %{role: "system", content: "You are a helpful agent."},
        %{role: "user", content: "Create a task called 'Deploy v2'"},
        %{
          role: "assistant",
          content: nil,
          tool_calls: [
            %{function: %{name: "use_skill", arguments: ~s({"skill":"tasks.create","title":"Deploy v2"})}}
          ]
        },
        %{role: "tool", content: "Task created: Deploy v2 (id: abc-123)"},
        %{role: "assistant", content: "Done! I created the task 'Deploy v2'."}
      ]

      result = Engine.serialize_transcript(messages)

      # System message stripped
      refute result =~ "helpful agent"

      # User message present
      assert result =~ "[user] Create a task called 'Deploy v2'"

      # Tool call annotation present
      assert result =~ "[tool_call] use_skill:"

      # Tool result present
      assert result =~ "[tool] Task created: Deploy v2"

      # Final assistant text present
      assert result =~ "[assistant] Done! I created the task"
    end
  end

  # -------------------------------------------------------------------
  # format_transcript_message/1
  # -------------------------------------------------------------------

  describe "format_transcript_message/1 — basic messages" do
    test "formats user message with content" do
      msg = %{role: "user", content: "Hello world"}
      assert Engine.format_transcript_message(msg) == "[user] Hello world"
    end

    test "formats assistant message with content" do
      msg = %{role: "assistant", content: "I can help with that."}
      assert Engine.format_transcript_message(msg) == "[assistant] I can help with that."
    end

    test "formats tool message with content" do
      msg = %{role: "tool", content: "Result: 42"}
      assert Engine.format_transcript_message(msg) == "[tool] Result: 42"
    end

    test "formats message with role only (no content key)" do
      msg = %{role: "assistant"}
      assert Engine.format_transcript_message(msg) == "[assistant]"
    end
  end

  describe "format_transcript_message/1 — assistant with tool_calls" do
    test "formats assistant message with tool calls and nil content" do
      msg = %{
        role: "assistant",
        content: nil,
        tool_calls: [
          %{function: %{name: "use_skill", arguments: ~s({"skill":"email.send"})}}
        ]
      }

      result = Engine.format_transcript_message(msg)

      assert result == "[assistant]\n[tool_call] use_skill: {\"skill\":\"email.send\"}"
    end

    test "formats assistant message with tool calls and empty content" do
      msg = %{
        role: "assistant",
        content: "",
        tool_calls: [
          %{function: %{name: "use_skill", arguments: ~s({"skill":"tasks.create"})}}
        ]
      }

      result = Engine.format_transcript_message(msg)

      assert result == "[assistant]\n[tool_call] use_skill: {\"skill\":\"tasks.create\"}"
    end

    test "formats assistant message with tool calls and text content" do
      msg = %{
        role: "assistant",
        content: "Let me create that task for you.",
        tool_calls: [
          %{function: %{name: "use_skill", arguments: ~s({"skill":"tasks.create"})}}
        ]
      }

      result = Engine.format_transcript_message(msg)

      assert result ==
               "[assistant] Let me create that task for you.\n[tool_call] use_skill: {\"skill\":\"tasks.create\"}"
    end

    test "formats multiple tool calls" do
      msg = %{
        role: "assistant",
        content: nil,
        tool_calls: [
          %{function: %{name: "use_skill", arguments: ~s({"skill":"email.list"})}},
          %{function: %{name: "use_skill", arguments: ~s({"skill":"tasks.search"})}}
        ]
      }

      result = Engine.format_transcript_message(msg)

      assert result =~ "[tool_call] use_skill: {\"skill\":\"email.list\"}"
      assert result =~ "[tool_call] use_skill: {\"skill\":\"tasks.search\"}"
      # Two tool_call lines
      assert length(String.split(result, "[tool_call]")) == 3
    end

    test "handles tool calls with string keys (JSON round-trip)" do
      msg = %{
        role: "assistant",
        content: nil,
        tool_calls: [
          %{"function" => %{"name" => "use_skill", "arguments" => ~s({"skill":"files.read"})}}
        ]
      }

      result = Engine.format_transcript_message(msg)

      assert result =~ "[tool_call] use_skill:"
      assert result =~ "files.read"
    end

    test "handles tool call with missing function name" do
      msg = %{
        role: "assistant",
        content: nil,
        tool_calls: [
          %{function: %{arguments: ~s({"data":"test"})}}
        ]
      }

      result = Engine.format_transcript_message(msg)

      assert result =~ "[tool_call] unknown:"
    end

    test "handles tool call with missing arguments" do
      msg = %{
        role: "assistant",
        content: nil,
        tool_calls: [
          %{function: %{name: "use_skill"}}
        ]
      }

      result = Engine.format_transcript_message(msg)

      assert result =~ "[tool_call] use_skill: "
    end

    test "does not match assistant with empty tool_calls list" do
      msg = %{role: "assistant", content: "Just text.", tool_calls: []}

      result = Engine.format_transcript_message(msg)

      # Should fall through to the content-only clause
      assert result == "[assistant] Just text."
    end
  end
end
