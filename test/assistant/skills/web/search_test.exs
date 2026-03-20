defmodule Assistant.Skills.Web.SearchTest do
  use Assistant.DataCase, async: false
  @moduletag :external

  import Assistant.AccountsFixtures
  import Assistant.ChannelFixtures

  alias Assistant.Accounts
  alias Assistant.Skills.Context
  alias Assistant.Skills.Result
  alias Assistant.Skills.Web.Search

  defmodule OpenRouterStub do
    def web_search(query, opts) do
      send(self(), {:openrouter_search, query, opts})

      {:ok,
       %{
         model: Keyword.fetch!(opts, :model),
         content: "OpenRouter answer",
         citations: [
           %{url: "https://example.com/a", title: "Source A", start_index: 0, end_index: 5}
         ]
       }}
    end
  end

  defmodule OpenAIStub do
    def web_search(query, opts) do
      send(self(), {:openai_search, query, opts})

      {:ok,
       %{
         model: Keyword.fetch!(opts, :model),
         content: "OpenAI answer",
         citations: [
           %{url: "https://example.com/b", title: "Source B", start_index: 0, end_index: 5}
         ]
       }}
    end
  end

  defmodule NoCitationStub do
    def web_search(_query, opts) do
      {:ok, %{model: Keyword.fetch!(opts, :model), content: "No citations", citations: []}}
    end
  end

  defmodule RateLimitedStub do
    def web_search(_query, _opts), do: {:error, {:rate_limited, 27}}
  end

  setup do
    original_openai_key = Application.get_env(:assistant, :openai_api_key)
    original_openrouter_key = Application.get_env(:assistant, :openrouter_api_key)

    Application.delete_env(:assistant, :openai_api_key)
    Application.delete_env(:assistant, :openrouter_api_key)

    on_exit(fn ->
      if original_openai_key do
        Application.put_env(:assistant, :openai_api_key, original_openai_key)
      else
        Application.delete_env(:assistant, :openai_api_key)
      end

      if original_openrouter_key do
        Application.put_env(:assistant, :openrouter_api_key, original_openrouter_key)
      else
        Application.delete_env(:assistant, :openrouter_api_key)
      end
    end)

    :ok
  end

  test "prefers OpenRouter by default and formats citations" do
    Application.put_env(:assistant, :openrouter_api_key, "test-openrouter-key")
    context = build_context(openrouter: OpenRouterStub, openai: OpenAIStub)

    assert {:ok, %Result{status: :ok, content: content, metadata: metadata}} =
             Search.execute(%{"query" => "elixir news"}, context)

    assert_received {:openrouter_search, "elixir news", opts}
    assert Keyword.has_key?(opts, :model)
    assert content =~ "OpenRouter answer"
    assert content =~ "Citations:"
    assert metadata.provider == "openrouter"
    assert [%{url: "https://example.com/a"}] = metadata.citations
  end

  test "uses OpenAI when explicitly requested and an API key is configured" do
    Application.put_env(:assistant, :openai_api_key, "test-openai-key")

    context = build_context(openrouter: OpenRouterStub, openai: OpenAIStub)

    assert {:ok, %Result{status: :ok, metadata: metadata}} =
             Search.execute(
               %{"query" => "phoenix release notes", "provider" => "openai"},
               context
             )

    assert_received {:openai_search, "phoenix release notes", opts}
    assert opts[:api_key] == "test-openai-key"
    assert metadata.provider == "openai"
  end

  test "returns an error when the provider response has no citations" do
    Application.put_env(:assistant, :openrouter_api_key, "test-openrouter-key")
    context = build_context(openrouter: NoCitationStub, openai: OpenAIStub)

    assert {:ok, %Result{status: :error, content: content}} =
             Search.execute(%{"query" => "citationless result"}, context)

    assert content =~ "no citations"
  end

  test "returns a clear error when no provider is configured" do
    context = build_context(%{})

    assert {:ok, %Result{status: :error, content: content}} =
             Search.execute(%{"query" => "elixir news"}, context)

    assert content =~ "No web search provider is configured"
  end

  test "returns a clear error when the provider is rate-limited" do
    Application.put_env(:assistant, :openrouter_api_key, "test-openrouter-key")
    context = build_context(%{openrouter: RateLimitedStub, openai: OpenAIStub})

    assert {:ok, %Result{status: :error, content: content}} =
             Search.execute(
               %{"query" => "latest phoenix news", "provider" => "openrouter"},
               context
             )

    assert content =~ "rate-limited"
    assert content =~ "27 seconds"
  end

  test "returns an oauth-only message for OpenAI connections without an API key" do
    settings_user = settings_user_fixture()
    chat_user = chat_user_fixture()

    settings_user
    |> Ecto.Changeset.change(%{user_id: chat_user.id})
    |> Repo.update!()

    {:ok, _settings_user} =
      Accounts.save_openai_oauth_credentials(settings_user, %{
        access_token: "oauth-access-token",
        refresh_token: "oauth-refresh-token",
        account_id: "acct_123"
      })

    context =
      build_context(%{openrouter: OpenRouterStub, openai: OpenAIStub}, user_id: chat_user.id)

    assert {:ok, %Result{status: :error, content: content}} =
             Search.execute(
               %{"query" => "latest elixir news", "provider" => "openai"},
               context
             )

    assert content =~ "OAuth/Codex-only"
    refute_received {:openai_search, _, _}
  end

  defp build_context(integrations, opts \\ []) do
    %Context{
      conversation_id: Ecto.UUID.generate(),
      execution_id: Ecto.UUID.generate(),
      user_id: Keyword.get(opts, :user_id, "unknown"),
      integrations: integrations
    }
  end
end
