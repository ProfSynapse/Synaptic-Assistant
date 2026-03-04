# lib/assistant/channels/message_formatter.ex — Converts markdown to platform-specific markup.
#
# LLM output uses standard markdown (bold, italic, links, headers, code blocks).
# Slack mrkdwn and Google Chat markup use a slightly different syntax. This module
# converts between them while preserving code blocks (inline and fenced) untouched.
#
# Conversion strategy: split text into code vs prose segments, apply conversions
# only to prose segments, then reassemble. This guarantees no formatting changes
# inside code blocks.
#
# Related files:
#   - lib/assistant/channels/dispatcher.ex (applies formatter before sending)
#   - lib/assistant/channels/google_chat.ex (Google Chat adapter)
#   - lib/assistant/channels/slack.ex (Slack adapter)

defmodule Assistant.Channels.MessageFormatter do
  @moduledoc """
  Converts standard markdown to platform-specific message formatting.

  LLM output uses standard markdown. Chat platforms like Slack and Google Chat
  use slightly different formatting syntax. This module bridges the gap.

  ## Supported Platforms

    * `:slack` — Slack mrkdwn format
    * `:google_chat` — Google Chat markup format

  Both platforms share nearly identical formatting rules, so they use the
  same conversion pipeline.

  ## Conversions

    * `**text**` → `*text*` (bold)
    * `~~text~~` → `~text~` (strikethrough)
    * `[text](url)` → `<url|text>` (links)
    * `# Header` → `*Header*` (headers → bold)
    * `> quote` → strips the `>` prefix
    * `---` / `***` → removed (horizontal rules)

  ## Preserved

    * Inline code (`` `code` ``)
    * Fenced code blocks (`` ``` ``)
    * `_italic_` (same in all formats)
    * `* list items` (same in all formats)

  ## Usage

      iex> MessageFormatter.format("**hello**", :slack)
      "*hello*"

      iex> MessageFormatter.format("**hello**", :telegram)
      "**hello**"
  """

  @platforms_with_mrkdwn [:slack, :google_chat]

  @doc """
  Format a text string for the given platform.

  Applies markdown-to-mrkdwn conversion for `:slack` and `:google_chat`.
  All other platforms pass through unchanged.

  Returns the original text for `nil` or empty input.
  """
  @spec format(String.t() | nil, atom()) :: String.t() | nil
  def format(nil, _platform), do: nil
  def format("", _platform), do: ""

  def format(text, platform) when platform in @platforms_with_mrkdwn do
    text
    |> split_code_segments()
    |> Enum.map(fn
      {:code, code} -> code
      {:prose, prose} -> convert_prose(prose)
    end)
    |> IO.iodata_to_binary()
  end

  def format(text, _platform), do: text

  # --- Code Block Splitting ---

  # Splits text into alternating {:prose, ...} and {:code, ...} segments.
  # Handles both fenced code blocks (```...```) and inline code (`...`).
  # Fenced blocks are checked first to avoid inline backticks inside fenced
  # blocks being treated as inline code boundaries.
  @spec split_code_segments(String.t()) :: [{:code | :prose, String.t()}]
  defp split_code_segments(text) do
    # Regex matches fenced code blocks (```...```) or inline code (`...`).
    # Fenced blocks: ``` optionally followed by language tag and newline.
    # Inline code: single backtick pairs (non-greedy).
    ~r/(```[^\n]*\n[\s\S]*?```|`[^`\n]+`)/
    |> Regex.split(text, include_captures: true)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(fn segment ->
      if String.starts_with?(segment, "`") do
        {:code, segment}
      else
        {:prose, segment}
      end
    end)
  end

  # --- Prose Conversions ---

  # Apply all markdown-to-mrkdwn conversions to a prose segment.
  defp convert_prose(text) do
    text
    |> convert_bold()
    |> convert_strikethrough()
    |> convert_links()
    |> convert_headers()
    |> convert_blockquotes()
    |> remove_horizontal_rules()
  end

  # **text** → *text* (bold: double asterisk to single)
  # Must not match single asterisks (italic/list items).
  defp convert_bold(text) do
    Regex.replace(~r/\*\*(.+?)\*\*/s, text, "*\\1*")
  end

  # ~~text~~ → ~text~ (strikethrough: double tilde to single)
  defp convert_strikethrough(text) do
    Regex.replace(~r/~~(.+?)~~/s, text, "~\\1~")
  end

  # [text](url) → <url|text> (markdown links to angle-bracket format)
  defp convert_links(text) do
    Regex.replace(~r/\[([^\]]+)\]\(([^)]+)\)/, text, "<\\2|\\1>")
  end

  # # Header / ## Header / ### Header → *Header* (headers to bold)
  # Only matches at start of line. Strips the # prefix and wraps in bold.
  defp convert_headers(text) do
    Regex.replace(~r/^\#{1,6}\s+(.+)$/m, text, "*\\1*")
  end

  # > blockquote → strips the > prefix, preserving the text.
  # Handles multiple consecutive blockquote lines.
  defp convert_blockquotes(text) do
    Regex.replace(~r/^>\s?/m, text, "")
  end

  # --- or *** or ___ → removed (horizontal rules)
  # These appear on their own line with optional whitespace.
  defp remove_horizontal_rules(text) do
    Regex.replace(~r/^\s*(?:---+|\*\*\*+|___+)\s*$/m, text, "")
  end
end
