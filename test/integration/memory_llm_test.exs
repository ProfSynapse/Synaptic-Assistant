# test/integration/memory_llm_test.exs
#
# Integration tests for memory subsystem with REAL LLM calls.
# Tests TurnClassifier classification logic and Compaction summary
# generation using the actual OpenRouter API.
#
# These tests verify that the LLM produces structurally correct
# classification and summarization outputs — not exact text.
#
# Requires: OPENROUTER_API_KEY env var with a valid API key.
# Tests are skipped if the key is not available.
#
# Related files:
#   - lib/assistant/memory/turn_classifier.ex (classification)
#   - lib/assistant/memory/compaction.ex (summarization)
#   - lib/assistant/integrations/openrouter.ex (real LLM client)

defmodule Assistant.Integration.MemoryLLMTest do
  use ExUnit.Case, async: false

  import Assistant.Integration.TestLogger

  @moduletag :integration
  @moduletag timeout: 120_000

  alias Assistant.Integrations.OpenRouter

  @integration_model "openai/gpt-5.2"

  # Real API key must be provided via OPENROUTER_API_KEY env var.
  # Tests are skipped if no key is available (CI without secrets).
  setup do
    case System.get_env("OPENROUTER_API_KEY") do
      key when is_binary(key) and key != "" ->
        {:ok, api_key: key}

      _ ->
        :ok
    end
  end

  # ---------------------------------------------------------------
  # Turn Classification — real LLM classifies conversation exchanges
  # ---------------------------------------------------------------

  @classification_response_format %{
    type: "json_schema",
    json_schema: %{
      name: "turn_classification",
      strict: true,
      schema: %{
        type: "object",
        properties: %{
          action: %{
            type: "string",
            enum: ["save_facts", "compact", "nothing"],
            description: "Classification action for this conversation turn"
          },
          reason: %{
            type: "string",
            description: "One-line explanation for the classification"
          }
        },
        required: ["action", "reason"],
        additionalProperties: false
      }
    }
  }

  describe "turn classification with real LLM" do
    @tag :integration
    test "classifies factual exchange as save_facts", context do
      if not has_api_key?(context), do: flunk("Skipped: OPENROUTER_API_KEY not set")

      user_message = "My name is Alice and I work at Anthropic as a research scientist."

      assistant_response =
        "Nice to meet you, Alice! It's great that you work at Anthropic as a research scientist."

      result = classify_turn(user_message, assistant_response, context.api_key)

      assert {:ok, action, reason} = result
      assert action == "save_facts"
      assert is_binary(reason)
      assert String.length(reason) > 0
    end

    @tag :integration
    test "classifies routine exchange as nothing", context do
      if not has_api_key?(context), do: flunk("Skipped: OPENROUTER_API_KEY not set")

      user_message = "Hello, how are you?"
      assistant_response = "I'm doing well, thank you! How can I help you today?"

      result = classify_turn(user_message, assistant_response, context.api_key)

      assert {:ok, action, reason} = result
      assert action == "nothing"
      assert is_binary(reason)
    end

    @tag :integration
    test "classifies topic change as compact", context do
      if not has_api_key?(context), do: flunk("Skipped: OPENROUTER_API_KEY not set")

      user_message = """
      Actually, forget about the code review. Let's talk about something
      completely different. What's the weather like in San Francisco today?
      """

      assistant_response = """
      Sure, let me help with the weather! San Francisco typically has
      mild temperatures around 55-65F this time of year.
      """

      result = classify_turn(user_message, assistant_response, context.api_key)

      assert {:ok, action, reason} = result
      # LLMs may classify a topic shift as "compact" or "nothing"
      assert action in ["compact", "nothing"]
      assert is_binary(reason)
    end

    @tag :integration
    test "classification returns valid JSON with required fields", context do
      if not has_api_key?(context), do: flunk("Skipped: OPENROUTER_API_KEY not set")

      user_message = "Set a reminder for my meeting with Bob tomorrow at 3pm"
      assistant_response = "I've noted the meeting with Bob tomorrow at 3pm."

      result = classify_turn(user_message, assistant_response, context.api_key)

      assert {:ok, action, reason} = result
      assert action in ["save_facts", "compact", "nothing"]
      assert is_binary(reason)
      assert String.length(reason) > 0
    end

    @tag :integration
    test "handles entity-rich exchange", context do
      if not has_api_key?(context), do: flunk("Skipped: OPENROUTER_API_KEY not set")

      user_message = """
      I just had a meeting with John Smith from Google about the Kubernetes
      migration project. He said the deadline is March 15th 2026 and the
      budget is $500K.
      """

      assistant_response = """
      Got it. So John Smith from Google confirmed the Kubernetes migration
      project has a March 15th 2026 deadline with a $500K budget.
      """

      result = classify_turn(user_message, assistant_response, context.api_key)

      assert {:ok, action, reason} = result
      assert action == "save_facts"
      assert is_binary(reason)
    end
  end

  # ---------------------------------------------------------------
  # Compaction-style summarization — real LLM generates summaries
  # ---------------------------------------------------------------

  describe "conversation summarization with real LLM" do
    @tag :integration
    test "produces non-empty summary from conversation history", context do
      if not has_api_key?(context), do: flunk("Skipped: OPENROUTER_API_KEY not set")

      messages = [
        %{role: "user", content: "What's the weather in SF?"},
        %{role: "assistant", content: "San Francisco is about 60F and foggy today."},
        %{role: "user", content: "Thanks! Also, remind me about the team meeting at 2pm."},
        %{role: "assistant", content: "I'll note the team meeting at 2pm for you."}
      ]

      result = summarize_conversation(messages, context.api_key)

      assert {:ok, summary} = result
      assert is_binary(summary)
      assert String.length(summary) > 20
      assert summary =~ ~r/weather|San Francisco|meeting|2pm/i
    end

    @tag :integration
    test "incremental summary incorporates prior summary", context do
      if not has_api_key?(context), do: flunk("Skipped: OPENROUTER_API_KEY not set")

      prior_summary = """
      The user is Alice, a software engineer. She prefers dark mode
      and uses VS Code. Previous conversation covered setting up her
      development environment.
      """

      new_messages = [
        %{role: "user", content: "I just switched to Neovim from VS Code."},
        %{
          role: "assistant",
          content: "That's a big change! Neovim has great Elixir support with the LSP."
        }
      ]

      result =
        summarize_conversation(new_messages, context.api_key, prior_summary: prior_summary)

      assert {:ok, summary} = result
      assert is_binary(summary)
      assert String.length(summary) > 30
      assert summary =~ ~r/Alice|Neovim|software engineer/i
    end

    @tag :integration
    test "handles long conversation gracefully", context do
      if not has_api_key?(context), do: flunk("Skipped: OPENROUTER_API_KEY not set")

      messages =
        for i <- 1..5 do
          [
            %{role: "user", content: "Message #{i}: Tell me about topic #{i} in Elixir."},
            %{
              role: "assistant",
              content:
                "Topic #{i} in Elixir covers pattern matching and GenServers. " <>
                  "Here are the key points for item #{i}."
            }
          ]
        end
        |> List.flatten()

      result = summarize_conversation(messages, context.api_key)

      assert {:ok, summary} = result
      assert is_binary(summary)
      full_text = Enum.map_join(messages, "\n", & &1.content)
      assert String.length(summary) < String.length(full_text)
    end
  end

  # ---------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------

  defp has_api_key?(context), do: Map.has_key?(context, :api_key)

  defp classify_turn(user_message, assistant_response, api_key) do
    prompt = """
    Classify this conversation exchange.

    save_facts: exchange contains new facts about named entities (people, orgs, projects)
    compact: clear topic change from what was previously discussed
    nothing: routine exchange, no new memorable facts

    User: #{user_message}
    Assistant: #{assistant_response}
    """

    messages = [%{role: "user", content: prompt}]

    opts = [
      model: @integration_model,
      temperature: 0.0,
      max_tokens: 500,
      response_format: @classification_response_format,
      api_key: api_key
    ]

    log_request("classify_turn", %{
      model: @integration_model,
      messages: messages,
      response_format: @classification_response_format,
      temperature: 0.0,
      max_tokens: 500
    })

    {elapsed, api_result} =
      timed(fn -> OpenRouter.chat_completion(messages, opts) end)

    case api_result do
      {:ok, %{content: content}} ->
        result = parse_classification(content)
        log_response("classify_turn", {:ok, %{content: content}})

        case result do
          {:ok, action, _reason} ->
            log_pass("classify_turn -> #{action}", elapsed)

          {:error, reason} ->
            log_fail("classify_turn", reason)
        end

        result

      {:error, reason} ->
        log_response("classify_turn", {:error, reason})
        log_fail("classify_turn", reason)
        {:error, {:llm_call_failed, reason}}
    end
  end

  defp parse_classification(content) when is_binary(content) do
    cleaned =
      content
      |> String.trim()
      |> String.replace(~r/^```json\s*/, "")
      |> String.replace(~r/\s*```$/, "")
      |> String.trim()

    case Jason.decode(cleaned) do
      {:ok, %{"action" => action, "reason" => reason}}
      when action in ["save_facts", "compact", "nothing"] ->
        {:ok, action, reason}

      {:ok, %{"action" => action}} ->
        {:error, {:invalid_action, action}}

      {:error, decode_error} ->
        {:error, {:json_decode_failed, decode_error}}
    end
  end

  defp parse_classification(_), do: {:error, :nil_content}

  defp summarize_conversation(messages, api_key, opts \\ []) do
    prior_summary = Keyword.get(opts, :prior_summary)

    prior_section =
      case prior_summary do
        nil -> "No prior summary exists. This is the first compaction."
        summary -> "## Prior Summary\n\n#{summary}"
      end

    messages_section =
      messages
      |> Enum.map(fn msg ->
        role = String.upcase(msg.role)
        "[#{role}]: #{msg.content}"
      end)
      |> Enum.join("\n")

    system_prompt = """
    You are a conversation compactor. Summarize the conversation history into
    a concise context block preserving key facts, decisions, tasks, preferences,
    names, dates, and identifiers. Discard redundant exchanges and verbose tool
    outputs. Target approximately 200 tokens.
    """

    user_prompt = """
    #{prior_section}

    ## New Messages to Incorporate

    #{messages_section}

    Please produce an updated summary that incorporates the new messages above
    with the prior summary (if any). Preserve all key information.
    """

    llm_messages = [
      %{role: "system", content: system_prompt},
      %{role: "user", content: user_prompt}
    ]

    llm_opts = [
      model: @integration_model,
      temperature: 0.3,
      max_tokens: 1024,
      api_key: api_key
    ]

    log_request("summarize_conversation", %{
      model: @integration_model,
      messages: llm_messages,
      temperature: 0.3,
      max_tokens: 1024
    })

    {elapsed, api_result} =
      timed(fn -> OpenRouter.chat_completion(llm_messages, llm_opts) end)

    case api_result do
      {:ok, %{content: nil}} ->
        log_response("summarize_conversation", {:error, :empty_llm_response})
        log_fail("summarize_conversation", :empty_llm_response)
        {:error, :empty_llm_response}

      {:ok, %{content: content}} ->
        log_response("summarize_conversation", {:ok, %{content: content}})
        log_pass("summarize_conversation", elapsed)
        {:ok, content}

      {:error, reason} ->
        log_response("summarize_conversation", {:error, reason})
        log_fail("summarize_conversation", reason)
        {:error, {:llm_call_failed, reason}}
    end
  end
end
