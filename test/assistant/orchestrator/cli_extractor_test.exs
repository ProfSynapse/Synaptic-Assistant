# test/assistant/orchestrator/cli_extractor_test.exs
#
# Tests for CLI command extraction from LLM output.
# Pure string processing — no state, no mocks.

defmodule Assistant.Orchestrator.CLIExtractorTest do
  use ExUnit.Case, async: true

  alias Assistant.Orchestrator.CLIExtractor

  # ---------------------------------------------------------------
  # extract/1
  # ---------------------------------------------------------------

  describe "extract/1" do
    test "returns empty for nil input" do
      assert %{commands: [], text: ""} = CLIExtractor.extract(nil)
    end

    test "returns empty for empty string" do
      assert %{commands: [], text: ""} = CLIExtractor.extract("")
    end

    test "returns text only when no cmd blocks" do
      result = CLIExtractor.extract("Hello, I can help with that.")
      assert result.commands == []
      assert result.text == "Hello, I can help with that."
    end

    test "extracts single command from cmd block" do
      output = """
      I'll search for overdue tasks.

      ```cmd
      tasks.search --status overdue
      ```

      Let me check.
      """

      result = CLIExtractor.extract(output)
      assert result.commands == ["tasks.search --status overdue"]
      assert result.text =~ "I'll search for overdue tasks."
      assert result.text =~ "Let me check."
      refute result.text =~ "```cmd"
    end

    test "extracts multiple commands from single block" do
      output = """
      Running two searches.

      ```cmd
      email.search --from bob
      tasks.search --status open
      ```
      """

      result = CLIExtractor.extract(output)
      assert length(result.commands) == 2
      assert "email.search --from bob" in result.commands
      assert "tasks.search --status open" in result.commands
    end

    test "extracts commands from multiple blocks" do
      output = """
      First, let me search.

      ```cmd
      email.search --from alice
      ```

      Found results. Now sending.

      ```cmd
      email.send --to bob --subject "FYI"
      ```
      """

      result = CLIExtractor.extract(output)
      assert length(result.commands) == 2
      assert "email.search --from alice" in result.commands
      assert ~s(email.send --to bob --subject "FYI") in result.commands
    end

    test "strips extra whitespace in commands" do
      output = """
      ```cmd
        tasks.search --status overdue
      ```
      """

      result = CLIExtractor.extract(output)
      assert result.commands == ["tasks.search --status overdue"]
    end

    test "ignores empty lines in cmd blocks" do
      output = """
      ```cmd

      tasks.search --status open

      ```
      """

      result = CLIExtractor.extract(output)
      assert result.commands == ["tasks.search --status open"]
    end

    test "preserves text around blocks without excessive newlines" do
      output = """
      Before.

      ```cmd
      tasks.search --status done
      ```

      After.
      """

      result = CLIExtractor.extract(output)
      refute result.text =~ "\n\n\n"
    end

    test "does not extract from non-cmd fenced blocks" do
      output = """
      Here's some code:

      ```python
      print("hello")
      ```

      Not a command.
      """

      result = CLIExtractor.extract(output)
      assert result.commands == []
      assert result.text =~ "```python"
    end
  end

  # ---------------------------------------------------------------
  # has_commands?/1
  # ---------------------------------------------------------------

  describe "has_commands?/1" do
    test "returns false for nil" do
      refute CLIExtractor.has_commands?(nil)
    end

    test "returns false for empty string" do
      refute CLIExtractor.has_commands?("")
    end

    test "returns false for text without cmd blocks" do
      refute CLIExtractor.has_commands?("Just a normal response.")
    end

    test "returns true when cmd block present" do
      assert CLIExtractor.has_commands?("text\n```cmd\ntasks.search\n```\nmore")
    end

    test "returns false for non-cmd code blocks" do
      refute CLIExtractor.has_commands?("```python\nprint('hi')\n```")
    end
  end
end
