# test/assistant/orchestrator/cli_parser_test.exs
#
# Tests for CLI command tokenization and flag parsing.
# tokenize/1 and parse_flags/1 are pure functions.
# parse/1 requires Registry (needs ETS + GenServer) — tested separately.

defmodule Assistant.Orchestrator.CLIParserTest do
  use ExUnit.Case, async: true

  alias Assistant.Orchestrator.CLIParser

  # ---------------------------------------------------------------
  # tokenize/1 — Shell-style tokenization
  # ---------------------------------------------------------------

  describe "tokenize/1" do
    test "splits simple words on whitespace" do
      assert {:ok, ["hello", "world"]} = CLIParser.tokenize("hello world")
    end

    test "handles double-quoted strings" do
      assert {:ok, ["email.send", "--subject", "Hello World"]} =
               CLIParser.tokenize(~s(email.send --subject "Hello World"))
    end

    test "handles single-quoted strings" do
      assert {:ok, ["email.send", "--subject", "Hello World"]} =
               CLIParser.tokenize("email.send --subject 'Hello World'")
    end

    test "preserves special characters inside quotes" do
      assert {:ok, ["cmd", "--arg", "value with --dashes"]} =
               CLIParser.tokenize(~s(cmd --arg "value with --dashes"))
    end

    test "handles equals-separated flags" do
      assert {:ok, ["cmd", "--flag=value"]} =
               CLIParser.tokenize("cmd --flag=value")
    end

    test "handles empty input" do
      assert {:ok, []} = CLIParser.tokenize("")
    end

    test "handles whitespace-only input" do
      assert {:ok, []} = CLIParser.tokenize("   ")
    end

    test "returns error for unterminated double quote" do
      assert {:error, {:tokenize_error, msg}} = CLIParser.tokenize(~s(cmd --arg "unterminated))
      assert msg =~ "double"
    end

    test "returns error for unterminated single quote" do
      assert {:error, {:tokenize_error, msg}} = CLIParser.tokenize("cmd --arg 'unterminated")
      assert msg =~ "single"
    end

    test "handles tabs as whitespace" do
      assert {:ok, ["a", "b"]} = CLIParser.tokenize("a\tb")
    end

    test "handles mixed quotes and regular tokens" do
      assert {:ok, ["email.send", "--to", "bob@co.com", "--subject", "Q1 Report"]} =
               CLIParser.tokenize(~s(email.send --to bob@co.com --subject "Q1 Report"))
    end

    test "adjacent quoted and unquoted characters form single token" do
      assert {:ok, ["hello"]} = CLIParser.tokenize(~s(he"ll"o))
    end
  end

  # ---------------------------------------------------------------
  # parse_flags/1 — Flag extraction
  # ---------------------------------------------------------------

  describe "parse_flags/1" do
    test "parses --flag=value format" do
      assert %{"to" => "bob@co.com"} = CLIParser.parse_flags(["--to=bob@co.com"])
    end

    test "parses --flag value format" do
      assert %{"to" => "bob@co.com"} = CLIParser.parse_flags(["--to", "bob@co.com"])
    end

    test "parses boolean flags (no value)" do
      assert %{"verbose" => true} = CLIParser.parse_flags(["--verbose"])
    end

    test "parses multiple flags" do
      tokens = ["--to", "bob@co.com", "--subject", "Hello", "--urgent"]
      flags = CLIParser.parse_flags(tokens)

      assert flags["to"] == "bob@co.com"
      assert flags["subject"] == "Hello"
      assert flags["urgent"] == true
    end

    test "collects multiple values as a list" do
      tokens = ["--tags", "important", "work", "--other", "val"]
      flags = CLIParser.parse_flags(tokens)

      assert flags["tags"] == ["important", "work"]
      assert flags["other"] == "val"
    end

    test "skips positional arguments" do
      tokens = ["positional", "--flag", "value"]
      flags = CLIParser.parse_flags(tokens)

      assert flags == %{"flag" => "value"}
    end

    test "empty token list produces empty map" do
      assert %{} == CLIParser.parse_flags([])
    end

    test "handles --flag=value with equals in value" do
      flags = CLIParser.parse_flags(["--query=status=open"])
      assert flags["query"] == "status=open"
    end
  end

  # ---------------------------------------------------------------
  # parse/1 — Full parsing (requires Registry)
  # ---------------------------------------------------------------

  describe "parse/1 edge cases" do
    test "returns error for empty string" do
      assert {:error, {:empty_command, _msg}} = CLIParser.parse("")
    end

    test "returns error for whitespace-only string" do
      assert {:error, {:empty_command, _msg}} = CLIParser.parse("   ")
    end

    test "returns error for unterminated quote" do
      assert {:error, {:tokenize_error, _msg}} = CLIParser.parse(~s(email.send --subject "broken))
    end
  end
end
