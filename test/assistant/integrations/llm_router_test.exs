defmodule Assistant.Integrations.LLMRouterTest do
  use ExUnit.Case, async: true

  alias Assistant.Integrations.LLMRouter

  describe "normalize_model_for_openai/1" do
    test "strips openai/ prefix for direct OpenAI use" do
      assert LLMRouter.normalize_model_for_openai("openai/gpt-5-mini") == "gpt-5-mini"
      assert LLMRouter.normalize_model_for_openai("openai/gpt-5.2") == "gpt-5.2"
    end

    test "passes through bare model names unchanged" do
      assert LLMRouter.normalize_model_for_openai("gpt-5-mini") == "gpt-5-mini"
      assert LLMRouter.normalize_model_for_openai("gpt-5.2-codex") == "gpt-5.2-codex"
    end

    test "passes through non-openai prefixed models unchanged" do
      assert LLMRouter.normalize_model_for_openai("anthropic/claude-sonnet-4.6") ==
               "anthropic/claude-sonnet-4.6"

      assert LLMRouter.normalize_model_for_openai("google/gemini-2.5-flash") ==
               "google/gemini-2.5-flash"
    end

    test "handles nil" do
      assert LLMRouter.normalize_model_for_openai(nil) == nil
    end
  end
end
