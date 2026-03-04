# test/assistant/channels/message_formatter_test.exs
#
# Tests for the MessageFormatter module. Verifies markdown-to-mrkdwn conversion
# for Slack and Google Chat, code block preservation, and passthrough for
# unsupported platforms.

defmodule Assistant.Channels.MessageFormatterTest do
  use ExUnit.Case, async: true

  alias Assistant.Channels.MessageFormatter

  # ---------------------------------------------------------------
  # Passthrough for unsupported platforms / nil / empty
  # ---------------------------------------------------------------

  describe "format/2 passthrough" do
    test "returns nil for nil input" do
      assert MessageFormatter.format(nil, :slack) == nil
    end

    test "returns empty string for empty input" do
      assert MessageFormatter.format("", :slack) == ""
    end

    test "passes through unchanged for :telegram" do
      text = "**bold** and [link](http://example.com)"
      assert MessageFormatter.format(text, :telegram) == text
    end

    test "passes through unchanged for :discord" do
      text = "**bold** and ~~strike~~"
      assert MessageFormatter.format(text, :discord) == text
    end

    test "passes through unchanged for unknown platform" do
      text = "**bold**"
      assert MessageFormatter.format(text, :unknown) == text
    end

    test "plain text without formatting passes through unchanged" do
      text = "Hello, how can I help you today?"
      assert MessageFormatter.format(text, :slack) == text
    end
  end

  # ---------------------------------------------------------------
  # Bold conversion: **text** → *text*
  # ---------------------------------------------------------------

  describe "format/2 bold conversion" do
    test "converts **bold** to *bold*" do
      assert MessageFormatter.format("**hello**", :slack) == "*hello*"
    end

    test "converts multiple bold segments" do
      assert MessageFormatter.format("**a** and **b**", :slack) == "*a* and *b*"
    end

    test "converts bold with spaces inside" do
      assert MessageFormatter.format("**bold text here**", :google_chat) == "*bold text here*"
    end

    test "preserves single asterisk (italic/list)" do
      assert MessageFormatter.format("*italic*", :slack) == "*italic*"
    end

    test "handles nested bold and italic: **_text_**" do
      assert MessageFormatter.format("**_bold italic_**", :slack) == "*_bold italic_*"
    end
  end

  # ---------------------------------------------------------------
  # Strikethrough conversion: ~~text~~ → ~text~
  # ---------------------------------------------------------------

  describe "format/2 strikethrough conversion" do
    test "converts ~~strike~~ to ~strike~" do
      assert MessageFormatter.format("~~removed~~", :slack) == "~removed~"
    end

    test "converts multiple strikethrough segments" do
      assert MessageFormatter.format("~~a~~ and ~~b~~", :google_chat) == "~a~ and ~b~"
    end

    test "preserves single tilde" do
      assert MessageFormatter.format("~approx~", :slack) == "~approx~"
    end
  end

  # ---------------------------------------------------------------
  # Link conversion: [text](url) → <url|text>
  # ---------------------------------------------------------------

  describe "format/2 link conversion" do
    test "converts markdown link to angle-bracket format" do
      assert MessageFormatter.format("[Google](https://google.com)", :slack) ==
               "<https://google.com|Google>"
    end

    test "converts multiple links" do
      text = "[A](http://a.com) and [B](http://b.com)"

      assert MessageFormatter.format(text, :slack) ==
               "<http://a.com|A> and <http://b.com|B>"
    end

    test "handles link text with spaces" do
      assert MessageFormatter.format("[click here](http://example.com)", :google_chat) ==
               "<http://example.com|click here>"
    end

    test "handles link with query params" do
      assert MessageFormatter.format("[search](https://google.com/search?q=test)", :slack) ==
               "<https://google.com/search?q=test|search>"
    end
  end

  # ---------------------------------------------------------------
  # Header conversion: # Header → *Header*
  # ---------------------------------------------------------------

  describe "format/2 header conversion" do
    test "converts h1 to bold" do
      assert MessageFormatter.format("# Title", :slack) == "*Title*"
    end

    test "converts h2 to bold" do
      assert MessageFormatter.format("## Subtitle", :slack) == "*Subtitle*"
    end

    test "converts h3 to bold" do
      assert MessageFormatter.format("### Section", :google_chat) == "*Section*"
    end

    test "converts h6 to bold" do
      assert MessageFormatter.format("###### Deep", :slack) == "*Deep*"
    end

    test "converts header at start of multiline text" do
      text = "# Title\n\nSome paragraph text."
      assert MessageFormatter.format(text, :slack) == "*Title*\n\nSome paragraph text."
    end

    test "converts multiple headers" do
      text = "# First\n\nText\n\n## Second"
      assert MessageFormatter.format(text, :slack) == "*First*\n\nText\n\n*Second*"
    end

    test "does not convert # in middle of line" do
      assert MessageFormatter.format("Issue #42 is fixed", :slack) == "Issue #42 is fixed"
    end
  end

  # ---------------------------------------------------------------
  # Blockquote conversion: > text → text
  # ---------------------------------------------------------------

  describe "format/2 blockquote conversion" do
    test "strips > prefix" do
      assert MessageFormatter.format("> quoted text", :slack) == "quoted text"
    end

    test "strips > from multiple lines" do
      text = "> line one\n> line two"
      assert MessageFormatter.format(text, :slack) == "line one\nline two"
    end

    test "handles > without space after" do
      assert MessageFormatter.format(">tight", :slack) == "tight"
    end
  end

  # ---------------------------------------------------------------
  # Horizontal rule removal
  # ---------------------------------------------------------------

  describe "format/2 horizontal rule removal" do
    test "removes ---" do
      text = "above\n\n---\n\nbelow"
      result = MessageFormatter.format(text, :slack)
      refute result =~ "---"
      assert result =~ "above"
      assert result =~ "below"
    end

    test "removes ***" do
      text = "above\n\n***\n\nbelow"
      result = MessageFormatter.format(text, :slack)
      refute result =~ "***"
      assert result =~ "above"
      assert result =~ "below"
    end

    test "removes ___" do
      text = "above\n\n___\n\nbelow"
      result = MessageFormatter.format(text, :slack)
      refute result =~ "___"
      assert result =~ "above"
      assert result =~ "below"
    end

    test "removes ---- (longer)" do
      text = "above\n\n----\n\nbelow"
      result = MessageFormatter.format(text, :slack)
      refute result =~ "----"
      assert result =~ "above"
      assert result =~ "below"
    end
  end

  # ---------------------------------------------------------------
  # Code block preservation
  # ---------------------------------------------------------------

  describe "format/2 code block preservation" do
    test "preserves inline code with bold syntax inside" do
      text = "Use `**bold**` for emphasis"
      assert MessageFormatter.format(text, :slack) == "Use `**bold**` for emphasis"
    end

    test "preserves fenced code block with formatting inside" do
      text = "Text\n```\n**bold** and ~~strike~~\n```\nMore text"

      assert MessageFormatter.format(text, :slack) ==
               "Text\n```\n**bold** and ~~strike~~\n```\nMore text"
    end

    test "preserves fenced code block with language tag" do
      text = "Example:\n```elixir\ndef **hello**, do: :ok\n```\nDone"

      assert MessageFormatter.format(text, :slack) ==
               "Example:\n```elixir\ndef **hello**, do: :ok\n```\nDone"
    end

    test "converts prose around code blocks" do
      text = "**before** `code here` **after**"
      assert MessageFormatter.format(text, :slack) == "*before* `code here` *after*"
    end

    test "handles multiple code blocks" do
      text = "**a** `code1` **b** `code2` **c**"
      assert MessageFormatter.format(text, :slack) == "*a* `code1` *b* `code2` *c*"
    end

    test "handles fenced block between formatted text" do
      text = "**intro**\n```\ncode\n```\n**outro**"
      assert MessageFormatter.format(text, :slack) == "*intro*\n```\ncode\n```\n*outro*"
    end

    test "preserves headers inside fenced code blocks" do
      text = "```\n# not a header\n## also not\n```"
      assert MessageFormatter.format(text, :slack) == "```\n# not a header\n## also not\n```"
    end

    test "preserves links inside inline code" do
      text = "Use `[text](url)` syntax"
      assert MessageFormatter.format(text, :slack) == "Use `[text](url)` syntax"
    end
  end

  # ---------------------------------------------------------------
  # Combined / complex formatting
  # ---------------------------------------------------------------

  describe "format/2 combined formatting" do
    test "converts multiple formatting types in one message" do
      text = "**Bold** and ~~strike~~ and [link](http://x.com)"

      assert MessageFormatter.format(text, :slack) ==
               "*Bold* and ~strike~ and <http://x.com|link>"
    end

    test "handles full message with headers, prose, and code" do
      text = """
      # Summary

      **Key findings**: the data shows ~~decline~~ growth.

      See [report](https://example.com/report) for details.

      ```python
      def analyze(**kwargs):
          return results
      ```

      ---

      ## Next Steps

      > Review the metrics
      > Update the dashboard\
      """

      result = MessageFormatter.format(text, :slack)

      # Headers converted
      assert result =~ "*Summary*"
      assert result =~ "*Next Steps*"
      # Bold converted
      assert result =~ "*Key findings*"
      # Strikethrough converted
      assert result =~ "~decline~"
      # Link converted
      assert result =~ "<https://example.com/report|report>"
      # Code block preserved
      assert result =~ "def analyze(**kwargs):"
      # Blockquotes stripped
      assert result =~ "Review the metrics"
      refute result =~ "> Review"
    end

    test "google_chat produces same output as slack" do
      text = "**bold** ~~strike~~ [link](http://x.com)"
      assert MessageFormatter.format(text, :slack) == MessageFormatter.format(text, :google_chat)
    end

    test "preserves list items with asterisk" do
      text = "* item one\n* item two\n* item three"
      assert MessageFormatter.format(text, :slack) == text
    end
  end
end
