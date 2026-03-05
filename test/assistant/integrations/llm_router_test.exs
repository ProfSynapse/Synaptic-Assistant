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

defmodule Assistant.Integrations.LLMRouter.RouteTest do
  @moduledoc """
  Tests for LLMRouter.route/2 credential-based routing logic.

  Uses DataCase for DB access since route/2 calls Accounts functions
  that query settings_users for per-user API keys.
  """
  use Assistant.DataCase, async: false

  alias Assistant.Accounts
  alias Assistant.Integrations.LLMRouter
  alias Assistant.Integrations.{OpenAI, OpenRouter}

  import Assistant.AccountsFixtures

  defp create_linked_user_and_settings_user(attrs \\ %{}) do
    # Create a chat user (external_id is NOT NULL in the DB)
    {:ok, user} =
      %Assistant.Schemas.User{}
      |> Assistant.Schemas.User.changeset(%{
        external_id: "test-#{System.unique_integer([:positive])}",
        channel: "test",
        display_name: "Test User"
      })
      |> Repo.insert()

    # Create a settings_user and link it to the chat user
    settings_user = settings_user_fixture()

    settings_user =
      settings_user
      |> Ecto.Changeset.change(Map.merge(%{user_id: user.id}, attrs))
      |> Repo.update!()

    {user, settings_user}
  end

  describe "route/2 priority 1: user has OpenRouter key" do
    test "routes to OpenRouter with the user's key" do
      {user, settings_user} = create_linked_user_and_settings_user()
      {:ok, _} = Accounts.save_openrouter_api_key(settings_user, "sk-or-user-key-123")

      result = LLMRouter.route("openai/gpt-5-mini", user.id)

      assert result.client == OpenRouter
      assert result.provider == :openrouter
      assert result.model == "openai/gpt-5-mini"
      assert result.api_key == "sk-or-user-key-123"
      assert result.openai_auth == nil
    end

    test "OpenRouter key wins when user has both OpenRouter and OpenAI keys" do
      {user, settings_user} = create_linked_user_and_settings_user()
      {:ok, _} = Accounts.save_openrouter_api_key(settings_user, "sk-or-both-key")
      {:ok, _} = Accounts.save_openai_api_key(settings_user, "sk-openai-both-key")

      result = LLMRouter.route("openai/gpt-5-mini", user.id)

      assert result.client == OpenRouter
      assert result.provider == :openrouter
      assert result.api_key == "sk-or-both-key"
    end
  end

  describe "route/2 priority 2: user has OpenAI key only" do
    test "routes to OpenAI and strips openai/ prefix" do
      {user, settings_user} = create_linked_user_and_settings_user()
      {:ok, _} = Accounts.save_openai_api_key(settings_user, "sk-openai-only-key")

      result = LLMRouter.route("openai/gpt-5-mini", user.id)

      assert result.client == OpenAI
      assert result.provider == :openai
      assert result.model == "gpt-5-mini"
      assert result.api_key == "sk-openai-only-key"
      assert result.openai_auth != nil
    end

    test "passes through non-openai model names unchanged" do
      {user, settings_user} = create_linked_user_and_settings_user()
      {:ok, _} = Accounts.save_openai_api_key(settings_user, "sk-openai-key")

      result = LLMRouter.route("gpt-5-mini", user.id)

      assert result.client == OpenAI
      assert result.model == "gpt-5-mini"
    end
  end

  describe "route/2 priority 3: no per-user credentials" do
    test "routes to OpenRouter with nil api_key when user has no keys" do
      {user, _settings_user} = create_linked_user_and_settings_user()

      result = LLMRouter.route("anthropic/claude-sonnet-4.6", user.id)

      assert result.client == OpenRouter
      assert result.provider == :openrouter
      assert result.model == "anthropic/claude-sonnet-4.6"
      assert result.api_key == nil
      assert result.openai_auth == nil
    end

    test "routes to OpenRouter with nil api_key for nil user_id" do
      result = LLMRouter.route("openai/gpt-5-mini", nil)

      assert result.client == OpenRouter
      assert result.provider == :openrouter
      assert result.model == "openai/gpt-5-mini"
      assert result.api_key == nil
      assert result.openai_auth == nil
    end
  end

  describe "route/2 edge cases" do
    test "empty string OpenRouter key is treated as no key" do
      {user, settings_user} = create_linked_user_and_settings_user()

      # Directly set empty string (bypassing save_openrouter_api_key validation)
      settings_user
      |> Ecto.Changeset.change(%{openrouter_api_key: ""})
      |> Repo.update!()

      result = LLMRouter.route("openai/gpt-5-mini", user.id)

      # Should NOT route to OpenRouter with empty key (priority 1 guard: key != "")
      # Falls to priority 3 (no credentials)
      assert result.api_key == nil
    end

    test "nil model passes through all routing tiers" do
      result = LLMRouter.route(nil, nil)

      assert result.client == OpenRouter
      assert result.model == nil
      assert result.api_key == nil
    end

    test "unknown user_id (valid UUID, no settings_user) routes to OpenRouter with nil" do
      fake_user_id = Ecto.UUID.generate()

      result = LLMRouter.route("openai/gpt-5-mini", fake_user_id)

      assert result.client == OpenRouter
      assert result.api_key == nil
    end
  end
end
