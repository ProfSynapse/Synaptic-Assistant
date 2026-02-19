# lib/assistant/orchestrator/cli_parser.ex — CLI command tokenizer and parser.
#
# Takes a raw CLI command string (e.g., "email.send --to bob@co.com --subject \"Hello\""),
# tokenizes it with shell-style quoting, resolves the skill name via the Registry,
# and parses flags into a structured ParsedCommand. Pure functions — no GenServer.
#
# The parser performs best-effort flag extraction. Validation of required flags,
# types, and enums is the handler's responsibility (Approach A per architecture).
# However, the parser does validate the command exists in the Registry and
# produces descriptive error messages for the LLM.
#
# Related files:
#   - lib/assistant/orchestrator/cli_extractor.ex (extracts commands from LLM output)
#   - lib/assistant/skills/registry.ex (skill lookup for command resolution)
#   - lib/assistant/skills/skill_definition.ex (SkillDefinition struct)

defmodule Assistant.Orchestrator.CLIParser do
  @moduledoc """
  Tokenizes and parses CLI command strings into structured commands.

  ## Pipeline

      "email.send --to bob@co.com --subject \\"Hello\\""
          |
          v
      Tokenizer (shell-style, respects quotes)
          -> ["email.send", "--to", "bob@co.com", "--subject", "Hello"]
          |
          v
      Command resolution (Registry lookup)
          -> {domain: "email", action: "send", skill_def: %SkillDefinition{}}
          |
          v
      Flag parser (best-effort, no schema)
          -> %{"to" => "bob@co.com", "subject" => "Hello"}
          |
          v
      %ParsedCommand{domain: "email", action: "send", flags: ..., raw: ...}

  ## Supported flag formats

    * `--flag=value` — equals-separated
    * `--flag value` — space-separated
    * `--bool-flag` — boolean (presence = true)
    * `--flag "value with spaces"` — quoted values
    * `--flag val1 val2` — multi-value (collected until next flag)
  """

  alias Assistant.Skills.{Registry, SkillDefinition}

  require Logger

  # --- ParsedCommand struct ---

  defmodule ParsedCommand do
    @moduledoc """
    Result of parsing a CLI command string.

    ## Fields

      * `:domain` - Domain segment (e.g., "email")
      * `:action` - Action segment (e.g., "send")
      * `:skill_name` - Full dot-notation name (e.g., "email.send")
      * `:skill_def` - The resolved `SkillDefinition` from the registry
      * `:flags` - Parsed flags as a string-keyed map
      * `:raw` - The original command string before parsing
    """

    @type t :: %__MODULE__{
            domain: String.t(),
            action: String.t(),
            skill_name: String.t(),
            skill_def: SkillDefinition.t(),
            flags: map(),
            raw: String.t()
          }

    @enforce_keys [:domain, :action, :skill_name, :skill_def, :flags, :raw]
    defstruct [:domain, :action, :skill_name, :skill_def, :flags, :raw]
  end

  # --- Public API ---

  @doc """
  Parse a raw CLI command string into a `ParsedCommand`.

  ## Parameters

    * `command_string` - Raw command text (e.g., "email.send --to bob@co.com")

  ## Returns

    * `{:ok, %ParsedCommand{}}` — Command successfully parsed and resolved
    * `{:error, reason}` — Descriptive error (shown to LLM as tool result)

  ## Error reasons

    * `{:empty_command, message}` — Blank or empty input
    * `{:tokenize_error, message}` — Malformed quoting
    * `{:unknown_skill, name, message}` — Skill not found in registry
    * `{:invalid_command_format, name, message}` — Not dot notation
    * `{:help_request, skill_name_or_domain}` — --help flag detected
  """
  @spec parse(String.t()) :: {:ok, ParsedCommand.t()} | {:error, term()}
  def parse(command_string) when is_binary(command_string) do
    trimmed = String.trim(command_string)

    if trimmed == "" do
      {:error, {:empty_command, "Empty command. Expected format: domain.action --flag value"}}
    else
      with {:ok, tokens} <- tokenize(trimmed),
           {:ok, skill_name, flag_tokens} <- extract_command_name(tokens),
           :ok <- check_help_flag(skill_name, flag_tokens),
           {:ok, skill_def} <- resolve_skill(skill_name),
           {:ok, domain, action} <- split_skill_name(skill_name) do
        flags = parse_flags(flag_tokens)

        {:ok,
         %ParsedCommand{
           domain: domain,
           action: action,
           skill_name: skill_name,
           skill_def: skill_def,
           flags: flags,
           raw: command_string
         }}
      end
    end
  end

  @doc """
  Tokenize a command string using shell-style rules.

  Splits on whitespace, respects double-quoted and single-quoted strings,
  and handles `--flag=value` splitting.

  ## Parameters

    * `input` - Raw command string

  ## Returns

    * `{:ok, [String.t()]}` — List of tokens
    * `{:error, {:tokenize_error, message}}` — Unterminated quote
  """
  @spec tokenize(String.t()) :: {:ok, [String.t()]} | {:error, {:tokenize_error, String.t()}}
  def tokenize(input) when is_binary(input) do
    input
    |> String.trim()
    |> do_tokenize([], [], nil)
  end

  @doc """
  Parse flag tokens into a string-keyed map.

  Best-effort parsing without a schema. Handles:
    * `--flag=value` — splits on first `=`
    * `--flag value` — next non-flag token is the value
    * `--bool-flag` — no following value, set to `true`
    * `--flag val1 val2` — multiple non-flag tokens collected as a list

  ## Parameters

    * `tokens` - List of token strings (flag portion, command name removed)

  ## Returns

    * A map of `%{String.t() => String.t() | [String.t()] | true}`
  """
  @spec parse_flags([String.t()]) :: map()
  def parse_flags(tokens) do
    do_parse_flags(tokens, %{})
  end

  # --- Tokenizer Implementation ---

  # Accumulates characters into tokens, tracking quote state.
  # current_chars: reversed charlist for the token being built
  # tokens: reversed list of completed tokens
  # quote_char: nil | ?" | ?' — which quote we are inside
  defp do_tokenize(<<>>, tokens, current_chars, nil) do
    tokens = finalize_token(tokens, current_chars)
    {:ok, Enum.reverse(tokens)}
  end

  defp do_tokenize(<<>>, _tokens, _current_chars, quote_char) do
    {:error, {:tokenize_error, "Unterminated #{quote_name(quote_char)} quote in command"}}
  end

  # Inside a quoted string: closing quote
  defp do_tokenize(<<char, rest::binary>>, tokens, current_chars, quote_char)
       when char == quote_char do
    do_tokenize(rest, tokens, current_chars, nil)
  end

  # Inside a quoted string: any other character
  defp do_tokenize(<<char, rest::binary>>, tokens, current_chars, quote_char)
       when not is_nil(quote_char) do
    do_tokenize(rest, tokens, [char | current_chars], quote_char)
  end

  # Outside quotes: opening double quote
  defp do_tokenize(<<?", rest::binary>>, tokens, current_chars, nil) do
    do_tokenize(rest, tokens, current_chars, ?")
  end

  # Outside quotes: opening single quote
  defp do_tokenize(<<?', rest::binary>>, tokens, current_chars, nil) do
    do_tokenize(rest, tokens, current_chars, ?')
  end

  # Outside quotes: whitespace (token boundary)
  defp do_tokenize(<<char, rest::binary>>, tokens, current_chars, nil)
       when char in [?\s, ?\t] do
    tokens = finalize_token(tokens, current_chars)
    do_tokenize(rest, tokens, [], nil)
  end

  # Outside quotes: any other character
  defp do_tokenize(<<char, rest::binary>>, tokens, current_chars, nil) do
    do_tokenize(rest, tokens, [char | current_chars], nil)
  end

  defp finalize_token(tokens, []), do: tokens

  defp finalize_token(tokens, chars) do
    token = chars |> Enum.reverse() |> List.to_string()
    [token | tokens]
  end

  defp quote_name(?"), do: "double"
  defp quote_name(?'), do: "single"

  # --- Command Name Extraction ---

  defp extract_command_name([]) do
    {:error,
     {:empty_command, "No command name found. Expected format: domain.action --flag value"}}
  end

  defp extract_command_name([name | rest]) do
    {:ok, name, rest}
  end

  # --- Help Flag Detection ---

  defp check_help_flag(skill_name, flag_tokens) do
    if "--help" in flag_tokens do
      {:error, {:help_request, skill_name}}
    else
      :ok
    end
  end

  # --- Skill Resolution ---

  defp resolve_skill(skill_name) do
    case Registry.lookup(skill_name) do
      {:ok, skill_def} ->
        {:ok, skill_def}

      {:error, :not_found} ->
        suggestion = suggest_skill(skill_name)

        message =
          "Unknown command '#{skill_name}'. " <>
            "Use `get_skill` to see available commands." <>
            if(suggestion, do: " Did you mean '#{suggestion}'?", else: "")

        {:error, {:unknown_skill, skill_name, message}}
    end
  end

  defp split_skill_name(skill_name) do
    case String.split(skill_name, ".", parts: 2) do
      [domain, action] ->
        {:ok, domain, action}

      _ ->
        {:error,
         {:invalid_command_format, skill_name,
          "Expected dot notation: domain.action (e.g., email.send, tasks.search)"}}
    end
  end

  # --- Flag Parser Implementation ---

  defp do_parse_flags([], acc), do: acc

  # Handle --flag=value (equals-separated)
  defp do_parse_flags(["--" <> flag_with_eq | rest], acc) do
    case String.split(flag_with_eq, "=", parts: 2) do
      [flag_name, value] ->
        do_parse_flags(rest, Map.put(acc, flag_name, value))

      [flag_name] ->
        {values, remaining} = collect_values(rest)

        case values do
          [] -> do_parse_flags(remaining, Map.put(acc, flag_name, true))
          [single] -> do_parse_flags(remaining, Map.put(acc, flag_name, single))
          multiple -> do_parse_flags(remaining, Map.put(acc, flag_name, multiple))
        end
    end
  end

  # Skip unexpected positional arguments (best-effort mode)
  defp do_parse_flags([_positional | rest], acc) do
    do_parse_flags(rest, acc)
  end

  # Collect non-flag tokens as values until the next flag or end
  defp collect_values(tokens) do
    Enum.split_while(tokens, fn token ->
      not String.starts_with?(token, "--")
    end)
  end

  # --- Skill Suggestion ---

  # Attempt a fuzzy match by checking if any registered skill name
  # shares the same domain or has a similar action name.
  defp suggest_skill(skill_name) do
    all_skills = Registry.list_all()

    case String.split(skill_name, ".", parts: 2) do
      [domain, _action] ->
        # Look for skills in the same domain
        same_domain =
          Enum.filter(all_skills, fn skill ->
            String.starts_with?(skill.name, domain <> ".")
          end)

        case same_domain do
          [first | _] -> first.name
          [] -> closest_match(skill_name, all_skills)
        end

      _ ->
        closest_match(skill_name, all_skills)
    end
  end

  defp closest_match(_name, []), do: nil

  defp closest_match(name, skills) do
    skills
    |> Enum.min_by(fn skill -> String.jaro_distance(name, skill.name) end, fn -> nil end)
    |> case do
      nil -> nil
      skill -> if String.jaro_distance(name, skill.name) > 0.6, do: skill.name, else: nil
    end
  end
end
