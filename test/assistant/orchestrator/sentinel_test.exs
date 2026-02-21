# test/assistant/orchestrator/sentinel_test.exs
#
# Unit tests for the Phase 2 Sentinel security gate. Uses Mox to mock the LLM
# client, covering all 10 scenarios from docs/preparation/sentinel-phase2.md
# plus error-handling paths (fail-open, malformed JSON, nil content).

defmodule Assistant.Orchestrator.SentinelTest do
  use ExUnit.Case, async: true

  import Mox

  alias Assistant.Orchestrator.Sentinel

  setup :verify_on_exit!

  # -------------------------------------------------------------------
  # Helpers
  # -------------------------------------------------------------------

  defp approve_response(reason) do
    {:ok,
     %{
       id: "sentinel-test",
       model: "test-model",
       content: Jason.encode!(%{"decision" => "approve", "reason" => reason}),
       tool_calls: [],
       finish_reason: "stop",
       usage: %{prompt_tokens: 50, completion_tokens: 20, total_tokens: 70}
     }}
  end

  defp reject_response(reason) do
    {:ok,
     %{
       id: "sentinel-test",
       model: "test-model",
       content: Jason.encode!(%{"decision" => "reject", "reason" => reason}),
       tool_calls: [],
       finish_reason: "stop",
       usage: %{prompt_tokens: 50, completion_tokens: 20, total_tokens: 70}
     }}
  end

  # -------------------------------------------------------------------
  # Category 1: OBVIOUS REJECT
  # -------------------------------------------------------------------

  describe "obvious reject scenarios" do
    test "scenario 1: wrong domain — search request but agent tries to send" do
      MockLLMClient
      |> expect(:chat_completion, fn _messages, _opts ->
        reject_response(
          "User requested email search, not email send. The action is not aligned with the request."
        )
      end)

      proposed_action = %{
        skill_name: "email.send",
        arguments: %{"to" => "sarah@example.com", "subject" => "Hi", "body" => "Hello"},
        agent_id: "email_agent"
      }

      assert {:ok, {:rejected, reason}} =
               Sentinel.check(
                 "Search my emails for messages from Sarah",
                 "Search the user's Gmail inbox for emails from Sarah",
                 proposed_action
               )

      assert reason =~ "search"
    end

    test "scenario 2: destructive action on read request" do
      MockLLMClient
      |> expect(:chat_completion, fn _messages, _opts ->
        reject_response(
          "User requested to view calendar events. Deleting a task is unrelated and destructive."
        )
      end)

      proposed_action = %{
        skill_name: "tasks.delete",
        arguments: %{"task_id" => "abc123"},
        agent_id: "calendar_agent"
      }

      assert {:ok, {:rejected, reason}} =
               Sentinel.check(
                 "Show me my upcoming calendar events",
                 "List the user's upcoming calendar events for the next 7 days",
                 proposed_action
               )

      assert reason =~ "destructive" or reason =~ "unrelated" or reason =~ "calendar"
    end
  end

  # -------------------------------------------------------------------
  # Category 2: OBVIOUS APPROVE
  # -------------------------------------------------------------------

  describe "obvious approve scenarios" do
    test "scenario 3: direct match — send email matching request" do
      MockLLMClient
      |> expect(:chat_completion, fn _messages, _opts ->
        approve_response("Direct alignment between request, mission, and action.")
      end)

      proposed_action = %{
        skill_name: "email.send",
        arguments: %{
          "to" => "john@example.com",
          "subject" => "Meeting Confirmed",
          "body" => "The meeting is confirmed."
        },
        agent_id: "email_agent"
      }

      assert {:ok, :approved} =
               Sentinel.check(
                 "Send an email to john@example.com saying the meeting is confirmed",
                 "Send an email to john@example.com confirming the meeting",
                 proposed_action
               )
    end

    test "scenario 4: read-only on read request" do
      MockLLMClient
      |> expect(:chat_completion, fn _messages, _opts ->
        approve_response("Read-only action matching user intent.")
      end)

      proposed_action = %{
        skill_name: "tasks.search",
        arguments: %{"due_before" => "2026-02-27"},
        agent_id: "task_agent"
      }

      assert {:ok, :approved} =
               Sentinel.check(
                 "What tasks do I have due this week?",
                 "Search for tasks due this week and summarize them",
                 proposed_action
               )
    end
  end

  # -------------------------------------------------------------------
  # Category 3: NUANCED PREREQUISITE
  # -------------------------------------------------------------------

  describe "nuanced prerequisite scenarios" do
    test "scenario 5: drive search before email — gathering info" do
      MockLLMClient
      |> expect(:chat_completion, fn _messages, _opts ->
        approve_response(
          "Agent needs to find the file before emailing it. Logical prerequisite step."
        )
      end)

      proposed_action = %{
        skill_name: "files.search",
        arguments: %{"query" => "budget report"},
        agent_id: "email_agent"
      }

      assert {:ok, :approved} =
               Sentinel.check(
                 "Email John the budget report from Google Drive",
                 "Find the budget report in Drive and email it to John",
                 proposed_action
               )
    end

    test "scenario 6: memory search before task creation" do
      MockLLMClient
      |> expect(:chat_completion, fn _messages, _opts ->
        approve_response(
          "Agent needs context from memory before creating the task. Logical prerequisite."
        )
      end)

      proposed_action = %{
        skill_name: "memory.search",
        arguments: %{"query" => "marketing campaign"},
        agent_id: "task_agent"
      }

      assert {:ok, :approved} =
               Sentinel.check(
                 "Create a task to follow up on what we discussed about the marketing campaign",
                 "Look up the marketing campaign discussion and create a follow-up task",
                 proposed_action
               )
    end
  end

  # -------------------------------------------------------------------
  # Category 4: NUANCED BOUNDARY
  # -------------------------------------------------------------------

  describe "nuanced boundary scenarios" do
    test "scenario 7: calendar create on check request — rejects" do
      MockLLMClient
      |> expect(:chat_completion, fn _messages, _opts ->
        reject_response("User requested to check/view calendar, not to create events.")
      end)

      proposed_action = %{
        skill_name: "calendar.create",
        arguments: %{"title" => "Follow-up", "start" => "2026-02-23T10:00"},
        agent_id: "calendar_agent"
      }

      assert {:ok, {:rejected, reason}} =
               Sentinel.check(
                 "Check my calendar for next Monday",
                 "Check the user's calendar for events on next Monday",
                 proposed_action
               )

      assert reason =~ "check" or reason =~ "view" or reason =~ "create"
    end

    test "scenario 8: draft email when user said 'tell' — approves" do
      MockLLMClient
      |> expect(:chat_completion, fn _messages, _opts ->
        approve_response(
          "'Tell Sarah' reasonably implies communication. Drafting is a cautious, low-risk interpretation."
        )
      end)

      proposed_action = %{
        skill_name: "email.draft",
        arguments: %{
          "to" => "sarah@example.com",
          "subject" => "Project Update",
          "body" => "Here is the project update..."
        },
        agent_id: "email_agent"
      }

      assert {:ok, :approved} =
               Sentinel.check(
                 "Tell Sarah about the project update",
                 "Communicate the project update to Sarah",
                 proposed_action
               )
    end
  end

  # -------------------------------------------------------------------
  # Category 5: MISSION SCOPE
  # -------------------------------------------------------------------

  describe "mission scope scenarios" do
    test "scenario 9: memory agent tries to email — rejects" do
      MockLLMClient
      |> expect(:chat_completion, fn _messages, _opts ->
        reject_response(
          "Agent mission is to search memory. Sending email is outside the scope of memory operations."
        )
      end)

      proposed_action = %{
        skill_name: "email.send",
        arguments: %{
          "to" => "bob@example.com",
          "subject" => "Meeting Notes",
          "body" => "Notes from our meeting..."
        },
        agent_id: "memory_agent"
      }

      assert {:ok, {:rejected, reason}} =
               Sentinel.check(
                 "What do you remember about my meeting with Bob?",
                 "Search memory for facts about meetings with Bob",
                 proposed_action
               )

      assert reason =~ "memory" or reason =~ "scope" or reason =~ "email"
    end

    test "scenario 10: task agent doing file operations — rejects" do
      MockLLMClient
      |> expect(:chat_completion, fn _messages, _opts ->
        reject_response(
          "Agent mission is task creation. Writing files is not within scope of task management."
        )
      end)

      proposed_action = %{
        skill_name: "files.write",
        arguments: %{"path" => "quarterly_review.md", "content" => "Review notes..."},
        agent_id: "task_agent"
      }

      assert {:ok, {:rejected, reason}} =
               Sentinel.check(
                 "Create a task to review the quarterly report",
                 "Create a follow-up task for reviewing the quarterly report",
                 proposed_action
               )

      assert reason =~ "task" or reason =~ "scope" or reason =~ "file"
    end
  end

  # -------------------------------------------------------------------
  # Fail-open: LLM errors result in approval
  # -------------------------------------------------------------------

  describe "fail-open behavior" do
    test "LLM timeout returns approved" do
      MockLLMClient
      |> expect(:chat_completion, fn _messages, _opts ->
        {:error, :timeout}
      end)

      proposed_action = %{
        skill_name: "email.send",
        arguments: %{"to" => "test@example.com"},
        agent_id: "email_agent"
      }

      assert {:ok, :approved} =
               Sentinel.check(
                 "Send an email",
                 "Send email to test",
                 proposed_action
               )
    end

    test "LLM rate limit returns approved" do
      MockLLMClient
      |> expect(:chat_completion, fn _messages, _opts ->
        {:error, {:rate_limited, "429 Too Many Requests"}}
      end)

      proposed_action = %{
        skill_name: "tasks.create",
        arguments: %{"title" => "New task"},
        agent_id: "task_agent"
      }

      assert {:ok, :approved} =
               Sentinel.check(
                 "Create a task",
                 "Create a new task",
                 proposed_action
               )
    end

    test "LLM network error returns approved" do
      MockLLMClient
      |> expect(:chat_completion, fn _messages, _opts ->
        {:error, :econnrefused}
      end)

      proposed_action = %{
        skill_name: "memory.save",
        arguments: %{"content" => "test"},
        agent_id: "memory_agent"
      }

      assert {:ok, :approved} =
               Sentinel.check(
                 "Remember this",
                 "Save to memory",
                 proposed_action
               )
    end
  end

  # -------------------------------------------------------------------
  # Malformed / unexpected LLM responses (fail-open via parse error)
  # -------------------------------------------------------------------

  describe "malformed LLM response handling" do
    test "non-JSON content fails open to approved" do
      MockLLMClient
      |> expect(:chat_completion, fn _messages, _opts ->
        {:ok,
         %{
           id: "sentinel-test",
           model: "test-model",
           content: "I think this should be approved because...",
           tool_calls: [],
           finish_reason: "stop",
           usage: %{prompt_tokens: 50, completion_tokens: 20, total_tokens: 70}
         }}
      end)

      proposed_action = %{
        skill_name: "email.list",
        arguments: %{},
        agent_id: "email_agent"
      }

      assert {:ok, :approved} =
               Sentinel.check("List emails", "List user emails", proposed_action)
    end

    test "JSON with unexpected decision value fails open to approved" do
      MockLLMClient
      |> expect(:chat_completion, fn _messages, _opts ->
        {:ok,
         %{
           id: "sentinel-test",
           model: "test-model",
           content: Jason.encode!(%{"decision" => "maybe", "reason" => "not sure"}),
           tool_calls: [],
           finish_reason: "stop",
           usage: %{prompt_tokens: 50, completion_tokens: 20, total_tokens: 70}
         }}
      end)

      proposed_action = %{
        skill_name: "tasks.get",
        arguments: %{"id" => "1"},
        agent_id: "task_agent"
      }

      assert {:ok, :approved} =
               Sentinel.check("Get task", "Retrieve task details", proposed_action)
    end

    test "nil content fails open to approved" do
      MockLLMClient
      |> expect(:chat_completion, fn _messages, _opts ->
        {:ok,
         %{
           id: "sentinel-test",
           model: "test-model",
           content: nil,
           tool_calls: [],
           finish_reason: "stop",
           usage: %{prompt_tokens: 50, completion_tokens: 20, total_tokens: 70}
         }}
      end)

      proposed_action = %{
        skill_name: "files.read",
        arguments: %{"path" => "test.txt"},
        agent_id: "file_agent"
      }

      assert {:ok, :approved} =
               Sentinel.check("Read file", "Read the file", proposed_action)
    end

    test "JSON wrapped in markdown code fences is parsed correctly" do
      MockLLMClient
      |> expect(:chat_completion, fn _messages, _opts ->
        {:ok,
         %{
           id: "sentinel-test",
           model: "test-model",
           content:
             "```json\n#{Jason.encode!(%{"decision" => "reject", "reason" => "Not aligned"})}\n```",
           tool_calls: [],
           finish_reason: "stop",
           usage: %{prompt_tokens: 50, completion_tokens: 20, total_tokens: 70}
         }}
      end)

      proposed_action = %{
        skill_name: "email.send",
        arguments: %{"to" => "test@example.com"},
        agent_id: "email_agent"
      }

      assert {:ok, {:rejected, "Not aligned"}} =
               Sentinel.check("Check email", "Check emails", proposed_action)
    end
  end

  # -------------------------------------------------------------------
  # Edge cases
  # -------------------------------------------------------------------

  describe "edge cases" do
    test "nil original_request — evaluates against mission scope only" do
      MockLLMClient
      |> expect(:chat_completion, fn messages, _opts ->
        # Verify the user message contains "(none)" for missing request
        user_msg = Enum.find(messages, &(&1.role == "user"))
        assert user_msg.content =~ "ORIGINAL REQUEST: (none)"

        approve_response("Action aligns with agent mission scope.")
      end)

      proposed_action = %{
        skill_name: "memory.search",
        arguments: %{"query" => "recent conversations"},
        agent_id: "memory_agent"
      }

      assert {:ok, :approved} =
               Sentinel.check(
                 nil,
                 "Search memory for recent conversation context",
                 proposed_action
               )
    end

    test "LLM receives correct message structure and options" do
      MockLLMClient
      |> expect(:chat_completion, fn messages, opts ->
        # Verify system + user message structure
        assert length(messages) == 2

        system_msg = Enum.at(messages, 0)
        assert system_msg.role == "system"
        assert system_msg.content =~ "security gate"

        user_msg = Enum.at(messages, 1)
        assert user_msg.role == "user"
        assert user_msg.content =~ "ORIGINAL REQUEST:"
        assert user_msg.content =~ "AGENT MISSION:"
        assert user_msg.content =~ "PROPOSED ACTION:"
        assert user_msg.content =~ "email.list"
        assert user_msg.content =~ "email_agent"

        # Verify opts
        assert opts[:temperature] == 0.0
        assert opts[:max_tokens] == 4096
        assert opts[:response_format] != nil

        approve_response("Aligned.")
      end)

      proposed_action = %{
        skill_name: "email.list",
        arguments: %{"limit" => 10},
        agent_id: "email_agent"
      }

      assert {:ok, :approved} =
               Sentinel.check("Show emails", "List recent emails", proposed_action)
    end

    test "arguments are JSON-encoded in the prompt" do
      MockLLMClient
      |> expect(:chat_completion, fn messages, _opts ->
        user_msg = Enum.find(messages, &(&1.role == "user"))
        # Arguments should be JSON-encoded, not Elixir inspect format
        assert user_msg.content =~ "\"to\""
        assert user_msg.content =~ "john@example.com"

        approve_response("Aligned.")
      end)

      proposed_action = %{
        skill_name: "email.send",
        arguments: %{"to" => "john@example.com", "subject" => "Test"},
        agent_id: "email_agent"
      }

      assert {:ok, :approved} =
               Sentinel.check("Send email to John", "Send email", proposed_action)
    end

    test "empty arguments map is handled" do
      MockLLMClient
      |> expect(:chat_completion, fn _messages, _opts ->
        approve_response("Aligned.")
      end)

      proposed_action = %{
        skill_name: "email.list",
        arguments: %{},
        agent_id: "email_agent"
      }

      assert {:ok, :approved} =
               Sentinel.check("Show emails", "List emails", proposed_action)
    end

    test "very long request and mission text does not crash" do
      MockLLMClient
      |> expect(:chat_completion, fn _messages, _opts ->
        approve_response("Aligned despite long input.")
      end)

      long_request = String.duplicate("search emails ", 200)
      long_mission = String.duplicate("find relevant messages ", 200)

      proposed_action = %{
        skill_name: "email.search",
        arguments: %{"query" => "test"},
        agent_id: "email_agent"
      }

      assert {:ok, :approved} =
               Sentinel.check(long_request, long_mission, proposed_action)
    end
  end
end
