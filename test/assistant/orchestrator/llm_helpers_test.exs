# test/assistant/orchestrator/llm_helpers_test.exs
#
# Tests for LLMHelpers — shared pure functions for extracting tool call
# names/args, classifying LLM responses, and extracting assistant text.
# These are foundational to every tool use chain in the system.

defmodule Assistant.Orchestrator.LLMHelpersTest do
  use ExUnit.Case, async: true

  alias Assistant.Orchestrator.LLMHelpers

  # ---------------------------------------------------------------
  # extract_function_name/1
  # ---------------------------------------------------------------

  describe "extract_function_name/1" do
    test "extracts name from atom-keyed tool call" do
      tc = %{id: "call_1", type: "function", function: %{name: "use_skill", arguments: "{}"}}
      assert LLMHelpers.extract_function_name(tc) == "use_skill"
    end

    test "extracts name from string-keyed tool call" do
      tc = %{"id" => "call_1", "type" => "function", "function" => %{"name" => "get_skill", "arguments" => "{}"}}
      assert LLMHelpers.extract_function_name(tc) == "get_skill"
    end

    test "returns 'unknown' for missing function key" do
      tc = %{id: "call_1", type: "function"}
      assert LLMHelpers.extract_function_name(tc) == "unknown"
    end

    test "returns 'unknown' for empty map" do
      assert LLMHelpers.extract_function_name(%{}) == "unknown"
    end

    test "returns 'unknown' for nil" do
      assert LLMHelpers.extract_function_name(nil) == "unknown"
    end

    test "returns 'unknown' for non-map input" do
      assert LLMHelpers.extract_function_name("not a map") == "unknown"
    end
  end

  # ---------------------------------------------------------------
  # extract_function_args/1
  # ---------------------------------------------------------------

  describe "extract_function_args/1" do
    test "decodes JSON string arguments with atom keys" do
      tc = %{function: %{name: "use_skill", arguments: ~s({"skill": "email.send", "to": "test@example.com"})}}
      args = LLMHelpers.extract_function_args(tc)

      assert args["skill"] == "email.send"
      assert args["to"] == "test@example.com"
    end

    test "decodes JSON string arguments with string keys" do
      tc = %{"function" => %{"name" => "use_skill", "arguments" => ~s({"skill": "email.send"})}}
      args = LLMHelpers.extract_function_args(tc)

      assert args["skill"] == "email.send"
    end

    test "passes through pre-decoded map arguments with atom keys" do
      tc = %{function: %{name: "use_skill", arguments: %{"skill" => "email.send"}}}
      args = LLMHelpers.extract_function_args(tc)

      assert args["skill"] == "email.send"
    end

    test "passes through pre-decoded map arguments with string keys" do
      tc = %{"function" => %{"name" => "use_skill", "arguments" => %{"skill" => "email.send"}}}
      args = LLMHelpers.extract_function_args(tc)

      assert args["skill"] == "email.send"
    end

    test "returns empty map for invalid JSON string" do
      tc = %{function: %{name: "use_skill", arguments: "not valid json {"}}
      assert LLMHelpers.extract_function_args(tc) == %{}
    end

    test "returns empty map for invalid JSON string with string keys" do
      tc = %{"function" => %{"name" => "use_skill", "arguments" => "{{invalid"}}
      assert LLMHelpers.extract_function_args(tc) == %{}
    end

    test "returns empty map for missing function key" do
      assert LLMHelpers.extract_function_args(%{}) == %{}
    end

    test "returns empty map for nil" do
      assert LLMHelpers.extract_function_args(nil) == %{}
    end

    test "handles empty JSON object string" do
      tc = %{function: %{name: "get_skill", arguments: "{}"}}
      assert LLMHelpers.extract_function_args(tc) == %{}
    end

    test "handles complex nested JSON arguments" do
      args_json = Jason.encode!(%{
        "skill" => "email.send",
        "arguments" => %{
          "to" => "user@example.com",
          "subject" => "Test",
          "body" => "Hello\nWorld"
        }
      })

      tc = %{function: %{name: "use_skill", arguments: args_json}}
      args = LLMHelpers.extract_function_args(tc)

      assert args["skill"] == "email.send"
      assert args["arguments"]["to"] == "user@example.com"
      assert args["arguments"]["body"] == "Hello\nWorld"
    end
  end

  # ---------------------------------------------------------------
  # text_response?/1
  # ---------------------------------------------------------------

  describe "text_response?/1" do
    test "returns true for text-only response" do
      response = %{content: "Here is the answer.", tool_calls: nil}
      assert LLMHelpers.text_response?(response) == true
    end

    test "returns true when tool_calls is empty list" do
      response = %{content: "Answer text", tool_calls: []}
      assert LLMHelpers.text_response?(response) == true
    end

    test "returns false when tool_calls present" do
      response = %{
        content: "I'll search for that.",
        tool_calls: [%{id: "call_1", type: "function", function: %{name: "use_skill", arguments: "{}"}}]
      }

      assert LLMHelpers.text_response?(response) == false
    end

    test "returns false when content is nil" do
      response = %{content: nil, tool_calls: nil}
      assert LLMHelpers.text_response?(response) == false
    end

    test "returns false when content is empty string" do
      response = %{content: "", tool_calls: nil}
      assert LLMHelpers.text_response?(response) == false
    end

    test "returns false when both content and tool_calls present" do
      response = %{
        content: "Some text",
        tool_calls: [%{id: "call_1", type: "function", function: %{name: "use_skill", arguments: "{}"}}]
      }

      assert LLMHelpers.text_response?(response) == false
    end
  end

  # ---------------------------------------------------------------
  # tool_call_response?/1
  # ---------------------------------------------------------------

  describe "tool_call_response?/1" do
    test "returns true when tool_calls is non-empty list" do
      response = %{
        content: nil,
        tool_calls: [%{id: "call_1", type: "function", function: %{name: "use_skill", arguments: "{}"}}]
      }

      assert LLMHelpers.tool_call_response?(response) == true
    end

    test "returns true with multiple tool calls" do
      response = %{
        content: nil,
        tool_calls: [
          %{id: "call_1", type: "function", function: %{name: "get_skill", arguments: "{}"}},
          %{id: "call_2", type: "function", function: %{name: "dispatch_agent", arguments: "{}"}}
        ]
      }

      assert LLMHelpers.tool_call_response?(response) == true
    end

    test "returns false when tool_calls is empty list" do
      response = %{content: "text", tool_calls: []}
      assert LLMHelpers.tool_call_response?(response) == false
    end

    test "returns false when tool_calls is nil" do
      response = %{content: "text", tool_calls: nil}
      assert LLMHelpers.tool_call_response?(response) == false
    end

    test "returns false when tool_calls key missing" do
      response = %{content: "text"}
      assert LLMHelpers.tool_call_response?(response) == false
    end
  end

  # ---------------------------------------------------------------
  # extract_last_assistant_text/1
  # ---------------------------------------------------------------

  describe "extract_last_assistant_text/1" do
    test "extracts last assistant content from message list" do
      messages = [
        %{role: "system", content: "You are a helpful assistant."},
        %{role: "user", content: "Search for emails"},
        %{role: "assistant", content: "I'll search for emails now."},
        %{role: "tool", tool_call_id: "tc1", content: "Found 3 results"},
        %{role: "assistant", content: "I found 3 emails matching your query."}
      ]

      assert LLMHelpers.extract_last_assistant_text(messages) == "I found 3 emails matching your query."
    end

    test "skips assistant messages with nil content" do
      messages = [
        %{role: "assistant", content: "First response"},
        %{role: "assistant", content: nil},
        %{role: "assistant", tool_calls: [%{id: "tc1"}]}
      ]

      assert LLMHelpers.extract_last_assistant_text(messages) == "First response"
    end

    test "skips assistant messages with empty string content" do
      messages = [
        %{role: "assistant", content: "Valid response"},
        %{role: "assistant", content: ""}
      ]

      assert LLMHelpers.extract_last_assistant_text(messages) == "Valid response"
    end

    test "returns nil when no assistant messages" do
      messages = [
        %{role: "system", content: "System prompt"},
        %{role: "user", content: "Hello"}
      ]

      assert LLMHelpers.extract_last_assistant_text(messages) == nil
    end

    test "returns nil for empty message list" do
      assert LLMHelpers.extract_last_assistant_text([]) == nil
    end

    test "handles messages with only tool_calls (no text content)" do
      messages = [
        %{role: "assistant", tool_calls: [%{id: "tc1", function: %{name: "use_skill"}}]},
        %{role: "tool", tool_call_id: "tc1", content: "result"}
      ]

      assert LLMHelpers.extract_last_assistant_text(messages) == nil
    end
  end

  # ---------------------------------------------------------------
  # build_llm_opts/3
  # ---------------------------------------------------------------

  describe "build_llm_opts/3" do
    test "builds opts with tools and model" do
      tools = [%{type: "function", function: %{name: "test"}}]
      opts = LLMHelpers.build_llm_opts(tools, "test/model")

      assert Keyword.get(opts, :tools) == tools
      assert Keyword.get(opts, :model) == "test/model"
    end

    test "omits model key when model is nil" do
      tools = [%{type: "function", function: %{name: "test"}}]
      opts = LLMHelpers.build_llm_opts(tools, nil)

      assert Keyword.get(opts, :tools) == tools
      refute Keyword.has_key?(opts, :model)
    end

    test "merges extra options" do
      tools = []
      opts = LLMHelpers.build_llm_opts(tools, "test/model", api_key: "sk-test", temperature: 0.5)

      assert Keyword.get(opts, :tools) == []
      assert Keyword.get(opts, :model) == "test/model"
      assert Keyword.get(opts, :api_key) == "sk-test"
      assert Keyword.get(opts, :temperature) == 0.5
    end

    test "handles empty tools list" do
      opts = LLMHelpers.build_llm_opts([], "test/model")
      assert Keyword.get(opts, :tools) == []
    end
  end
end
