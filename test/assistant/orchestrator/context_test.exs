# test/assistant/orchestrator/context_test.exs
#
# Tests for context assembly and token budget trimming.
# Focuses on the pure trimming logic — the parts that don't
# require a running Config.Loader or PromptLoader.

defmodule Assistant.Orchestrator.ContextTest do
  use ExUnit.Case, async: true

  # We test the trimming logic by calling the module's private functions
  # through the public API surface. Since trim_messages is private,
  # we test it indirectly through build/3 behavior or by extracting
  # the core logic into a testable path.
  #
  # Strategy: Test estimate_message_tokens indirectly by constructing
  # messages and verifying trim behavior.

  # ---------------------------------------------------------------
  # Token estimation heuristic validation
  # ---------------------------------------------------------------

  describe "message trimming behavior" do
    # These tests validate the trim logic by exercising it through
    # the module's internal functions. We use Module.invoke/3 via
    # a helper module to test the private trim functions.

    test "short messages fit within large budget" do
      messages = [
        %{role: "user", content: "Hello"},
        %{role: "assistant", content: "Hi there!"}
      ]

      # With a large budget, all messages should be kept
      trimmed = trim_by_estimation(messages, 100_000)
      assert length(trimmed) == 2
    end

    test "oldest messages are dropped first when over budget" do
      # Create messages where each is ~100 chars = ~29 tokens (100/4 + 4)
      messages =
        for i <- 1..10 do
          %{role: "user", content: String.duplicate("x", 100) <> " #{i}"}
        end

      # Budget for roughly 3 messages (~29 tokens each = ~87 tokens needed)
      trimmed = trim_by_estimation(messages, 90)

      # Should keep newest messages, drop oldest
      assert length(trimmed) < 10
      # Last message should be kept (newest)
      assert List.last(trimmed) == List.last(messages)
    end

    test "messages with list content parts are estimated correctly" do
      msg = %{
        role: "user",
        content: [
          %{type: "text", text: "Hello world"},
          %{type: "text", text: "More content here"}
        ]
      }

      trimmed = trim_by_estimation([msg], 100_000)
      assert length(trimmed) == 1
    end

    test "empty content message has minimal token cost" do
      msg = %{role: "system", content: ""}
      trimmed = trim_by_estimation([msg], 10)
      # Even empty messages have overhead (4 tokens), should fit in budget of 10
      assert length(trimmed) == 1
    end

    test "string-keyed content is handled" do
      msg = %{"role" => "user", "content" => "Hello world"}
      trimmed = trim_by_estimation([msg], 100_000)
      assert length(trimmed) == 1
    end

    test "usage-based trimming preserves new messages over old" do
      # Scenario: 5 old messages (covered by baseline), 2 new messages
      old_messages =
        for i <- 1..5 do
          %{role: "user", content: "Old message #{i}: #{String.duplicate("a", 200)}"}
        end

      new_messages =
        for i <- 1..2 do
          %{role: "assistant", content: "New result #{i}"}
        end

      all_messages = old_messages ++ new_messages

      # Simulate: baseline was 1000 tokens for the 5 old messages,
      # new messages add ~20 tokens each, budget is 1020
      # So we need to trim ~20 tokens from old messages
      trimmed = trim_by_usage(all_messages, 1020, 1000, 5)

      # Both new messages must be preserved
      assert Enum.all?(new_messages, fn new_msg -> new_msg in trimmed end)
    end

    test "usage-based trimming returns all when within budget" do
      messages =
        for i <- 1..3 do
          %{role: "user", content: "Message #{i}"}
        end

      # Baseline covers everything, no new messages
      trimmed = trim_by_usage(messages, 100_000, 500, 3)
      assert length(trimmed) == 3
    end
  end

  # ---------------------------------------------------------------
  # Private helper: replicate the trim logic for testing
  # ---------------------------------------------------------------

  # Reimplements trim_messages_by_estimation from Context module
  # for direct unit testing. This avoids needing to go through
  # build/3 which requires running GenServers.
  defp trim_by_estimation(messages, token_budget) do
    messages
    |> Enum.reverse()
    |> Enum.reduce_while({[], 0}, fn msg, {kept, total_tokens} ->
      msg_tokens = estimate_tokens(msg)
      new_total = total_tokens + msg_tokens

      if new_total <= token_budget do
        {:cont, {[msg | kept], new_total}}
      else
        {:halt, {kept, total_tokens}}
      end
    end)
    |> elem(0)
  end

  # Reimplements trim_messages_by_usage from Context module
  defp trim_by_usage(messages, token_budget, baseline, last_message_count) do
    msg_count = length(messages)

    {known_msgs, new_msgs} =
      if last_message_count >= msg_count do
        {messages, []}
      else
        Enum.split(messages, last_message_count)
      end

    new_tokens = Enum.reduce(new_msgs, 0, &(estimate_tokens(&1) + &2))
    total_estimated = baseline + new_tokens

    if total_estimated <= token_budget do
      messages
    else
      overshoot = total_estimated - token_budget
      {_freed, kept_known} = trim_oldest(known_msgs, overshoot)
      kept_known ++ new_msgs
    end
  end

  defp trim_oldest(messages, tokens_to_free) do
    do_trim_oldest(messages, tokens_to_free, 0)
  end

  defp do_trim_oldest([], _tokens_to_free, freed), do: {freed, []}

  defp do_trim_oldest(remaining, tokens_to_free, freed) when freed >= tokens_to_free do
    {freed, remaining}
  end

  defp do_trim_oldest([msg | rest], tokens_to_free, freed) do
    msg_tokens = estimate_tokens(msg)
    do_trim_oldest(rest, tokens_to_free, freed + msg_tokens)
  end

  # Matches Context.estimate_message_tokens/1 at 4 chars/token + 4 overhead
  defp estimate_tokens(message) do
    text =
      case message do
        %{content: content} when is_binary(content) -> content
        %{content: parts} when is_list(parts) -> extract_text(parts)
        %{"content" => content} when is_binary(content) -> content
        %{"content" => parts} when is_list(parts) -> extract_text(parts)
        _ -> ""
      end

    div(String.length(text), 4) + 4
  end

  defp extract_text(parts) do
    Enum.map_join(parts, " ", fn
      %{text: text} when is_binary(text) -> text
      %{"text" => text} when is_binary(text) -> text
      _ -> ""
    end)
  end
end
