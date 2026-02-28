# test/assistant/skills/result_test.exs — Tests for SkillResult truncation.

defmodule Assistant.Skills.ResultTest do
  use ExUnit.Case, async: true

  alias Assistant.Skills.Result

  describe "truncate_content/1" do
    test "returns nil for nil input" do
      assert Result.truncate_content(nil) == nil
    end

    test "returns short content unchanged" do
      assert Result.truncate_content("hello") == "hello"
    end

    test "returns content at exactly the limit unchanged" do
      content = String.duplicate("a", 100_000)
      assert Result.truncate_content(content) == content
    end

    test "truncates content exceeding the limit" do
      content = String.duplicate("a", 100_001)
      result = Result.truncate_content(content)

      assert String.length(result) < String.length(content)
      assert result =~ "[Truncated"
      assert result =~ "100000 character limit"
    end

    test "truncated content starts with the original prefix" do
      content = "PREFIX" <> String.duplicate("x", 100_000)
      result = Result.truncate_content(content)

      assert String.starts_with?(result, "PREFIX")
    end

    test "returns empty string unchanged" do
      assert Result.truncate_content("") == ""
    end
  end
end
