# lib/assistant/orchestrator/cli_extractor.ex — Extracts CLI commands from LLM output.
#
# Detects ```cmd fenced blocks in the LLM's response text, extracts the
# command strings, and returns both the commands and the remaining
# conversational text. Pure string processing — no GenServer, no state.
#
# Used by the Engine to separate actionable commands from the assistant's
# natural language response before routing commands to the CLI parser.
#
# Related files:
#   - lib/assistant/orchestrator/cli_parser.ex (parses extracted commands)
#   - lib/assistant/orchestrator/engine.ex (calls extract/1 on LLM output)

defmodule Assistant.Orchestrator.CLIExtractor do
  @moduledoc """
  Extracts CLI command strings from LLM output text.

  The LLM outputs commands inside ` ```cmd ` fenced code blocks. Text
  outside these blocks is the conversational response to the user.
  Each ` ```cmd ` block may contain one or more commands (one per line).

  ## Example

      iex> output = \"""
      ...> I'll search for overdue tasks.
      ...>
      ...> ```cmd
      ...> tasks.search --status overdue
      ...> ```
      ...>
      ...> Found 3 results.
      ...> \"""
      iex> CLIExtractor.extract(output)
      %{commands: ["tasks.search --status overdue"], text: "I'll search for overdue tasks.\\n\\nFound 3 results."}
  """

  @cmd_fence_regex ~r/```cmd\s*\n(.*?)\n\s*```/s

  @doc """
  Extract CLI commands from LLM output text.

  Returns a map with:
    * `:commands` - List of command strings (one per line, trimmed)
    * `:text` - Remaining conversational text with fenced blocks removed

  ## Parameters

    * `llm_output` - Raw text output from the LLM

  ## Returns

    * `%{commands: [String.t()], text: String.t()}`

  Empty or nil input returns an empty commands list and empty text.
  """
  @spec extract(String.t() | nil) :: %{commands: [String.t()], text: String.t()}
  def extract(nil), do: %{commands: [], text: ""}
  def extract(""), do: %{commands: [], text: ""}

  def extract(llm_output) when is_binary(llm_output) do
    commands =
      @cmd_fence_regex
      |> Regex.scan(llm_output)
      |> Enum.flat_map(fn [_full_match, block_content] ->
        block_content
        |> String.split("\n", trim: true)
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))
      end)

    text =
      @cmd_fence_regex
      |> Regex.replace(llm_output, "")
      |> String.replace(~r/\n{3,}/, "\n\n")
      |> String.trim()

    %{commands: commands, text: text}
  end

  @doc """
  Check if the LLM output contains any ` ```cmd ` fenced blocks.

  Useful for the engine to decide whether to route through the CLI
  pipeline or treat the output as a plain text response.

  ## Parameters

    * `llm_output` - Raw text output from the LLM

  ## Returns

    * `true` if at least one ` ```cmd ` block is found
  """
  @spec has_commands?(String.t() | nil) :: boolean()
  def has_commands?(nil), do: false
  def has_commands?(""), do: false

  def has_commands?(llm_output) when is_binary(llm_output) do
    Regex.match?(@cmd_fence_regex, llm_output)
  end
end
