defmodule Assistant.Integrations.LLMRouterTest do
  use ExUnit.Case, async: true

  alias Assistant.Integrations.LLMRouter

  describe "openai_model?/1" do
    test "detects openai-prefixed model ids" do
      assert LLMRouter.openai_model?("openai/gpt-5-mini")
      refute LLMRouter.openai_model?("anthropic/claude-sonnet-4.6")
      refute LLMRouter.openai_model?(nil)
    end
  end

  describe "strip_openai_prefix/1" do
    test "strips openai/ prefix when present" do
      assert LLMRouter.strip_openai_prefix("openai/gpt-5-mini") == "gpt-5-mini"
      assert LLMRouter.strip_openai_prefix("gpt-5-mini") == "gpt-5-mini"
      assert LLMRouter.strip_openai_prefix(nil) == nil
    end
  end
end
