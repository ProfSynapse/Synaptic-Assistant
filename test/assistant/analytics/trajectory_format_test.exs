# test/assistant/analytics/trajectory_format_test.exs — Tests for trajectory
# data formatting.

defmodule Assistant.Analytics.TrajectoryFormatTest do
  use ExUnit.Case, async: true

  alias Assistant.Analytics.TrajectoryFormat

  describe "build_turn_entry/1" do
    test "builds a complete turn entry with all fields" do
      attrs = %{
        conversation_id: "conv-123",
        user_id: "user-456",
        channel: :google_chat,
        mode: :multi_agent,
        model: "anthropic/claude-sonnet-4.6",
        user_message: "Send an email",
        assistant_response: "Done!",
        messages: [
          %{role: "user", content: "Send an email"},
          %{role: "assistant", content: "Done!"}
        ],
        dispatched_agents: %{
          "email-agent" => %{
            status: :completed,
            result: "Email sent",
            tool_calls_used: 2,
            duration_ms: 1500
          }
        },
        usage: %{prompt_tokens: 100, completion_tokens: 50},
        iteration_count: 3
      }

      entry = TrajectoryFormat.build_turn_entry(attrs)

      assert entry.type == "turn"
      assert entry.version == 1
      assert entry.conversation_id == "conv-123"
      assert entry.user_id == "user-456"
      assert entry.channel == "google_chat"
      assert entry.mode == "multi_agent"
      assert entry.model == "anthropic/claude-sonnet-4.6"
      assert entry.user_message == "Send an email"
      assert entry.assistant_response == "Done!"
      assert entry.iteration_count == 3
      assert is_binary(entry.timestamp)

      assert length(entry.messages) == 2
      assert [%{index: 0, role: "user"}, %{index: 1, role: "assistant"}] = entry.messages

      assert length(entry.agents) == 1
      [agent] = entry.agents
      assert agent.agent_id == "email-agent"
      assert agent.status == "completed"
      assert agent.result == "Email sent"
      assert agent.tool_calls_used == 2

      assert entry.usage.prompt_tokens == 100
      assert entry.usage.completion_tokens == 50
    end

    test "handles missing optional fields gracefully" do
      entry = TrajectoryFormat.build_turn_entry(%{})

      assert entry.type == "turn"
      assert entry.conversation_id == nil
      assert entry.messages == []
      assert entry.agents == []
      assert entry.usage.prompt_tokens == 0
    end

    test "formats tool calls in messages" do
      attrs = %{
        messages: [
          %{
            role: "assistant",
            tool_calls: [
              %{
                id: "tc-1",
                function: %{name: "get_skill", arguments: ~s({"query":"email"})}
              }
            ]
          }
        ]
      }

      entry = TrajectoryFormat.build_turn_entry(attrs)
      [msg] = entry.messages

      assert msg.role == "assistant"
      assert [tc] = msg.tool_calls
      assert tc.id == "tc-1"
      assert tc.function.name == "get_skill"
    end

    test "formats tool result messages" do
      attrs = %{
        messages: [
          %{role: "tool", tool_call_id: "tc-1", content: "Result text"}
        ]
      }

      entry = TrajectoryFormat.build_turn_entry(attrs)
      [msg] = entry.messages

      assert msg.role == "tool"
      assert msg.tool_call_id == "tc-1"
      assert msg.content == "Result text"
    end

    test "truncates long agent results" do
      attrs = %{
        dispatched_agents: %{
          "agent-1" => %{
            status: :completed,
            result: String.duplicate("x", 3000),
            tool_calls_used: 1,
            duration_ms: 100
          }
        }
      }

      entry = TrajectoryFormat.build_turn_entry(attrs)
      [agent] = entry.agents

      assert String.length(agent.result) <= 2003
      assert String.ends_with?(agent.result, "...")
    end
  end

  describe "build_conversation_entry/2" do
    test "builds a conversation entry from schema structs" do
      conversation = %{
        id: "conv-1",
        user_id: "user-1",
        channel: "google_chat",
        agent_type: "orchestrator",
        status: "active",
        parent_conversation_id: nil,
        started_at: ~U[2026-02-28 10:00:00Z],
        last_active_at: ~U[2026-02-28 10:05:00Z],
        summary: "User asked about email",
        summary_version: 1
      }

      messages = [
        %{
          id: "msg-1",
          role: "user",
          content: "Hello",
          tool_calls: nil,
          tool_results: nil,
          token_count: 5,
          inserted_at: ~U[2026-02-28 10:00:00Z]
        },
        %{
          id: "msg-2",
          role: "assistant",
          content: "Hi!",
          tool_calls: nil,
          tool_results: nil,
          token_count: 3,
          inserted_at: ~U[2026-02-28 10:00:01Z]
        }
      ]

      entry = TrajectoryFormat.build_conversation_entry(conversation, messages)

      assert entry.type == "conversation"
      assert entry.version == 1
      assert entry.conversation_id == "conv-1"
      assert entry.message_count == 2
      assert entry.summary == "User asked about email"
      assert length(entry.messages) == 2
    end
  end
end
