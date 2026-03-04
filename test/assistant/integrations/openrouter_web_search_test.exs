defmodule Assistant.Integrations.OpenRouterWebSearchTest do
  use ExUnit.Case, async: false

  alias Assistant.Integrations.OpenRouter

  test "web_search/2 posts plugin request and returns normalized citations" do
    bypass = Bypass.open()
    original_base_url = Application.get_env(:assistant, :openrouter_base_url)
    original_api_key = Application.get_env(:assistant, :openrouter_api_key)

    Application.put_env(
      :assistant,
      :openrouter_base_url,
      "http://127.0.0.1:#{bypass.port}/api/v1"
    )

    Application.put_env(:assistant, :openrouter_api_key, "test-openrouter-key")

    on_exit(fn ->
      if original_base_url,
        do: Application.put_env(:assistant, :openrouter_base_url, original_base_url),
        else: Application.delete_env(:assistant, :openrouter_base_url)

      if original_api_key,
        do: Application.put_env(:assistant, :openrouter_api_key, original_api_key),
        else: Application.delete_env(:assistant, :openrouter_api_key)
    end)

    Bypass.expect_once(bypass, "POST", "/api/v1/chat/completions", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      decoded = Jason.decode!(body)

      assert decoded["plugins"] == [%{"id" => "web", "engine" => "native", "max_results" => 3}]
      assert decoded["messages"] == [%{"role" => "user", "content" => "latest phoenix news"}]

      Plug.Conn.resp(
        conn,
        200,
        Jason.encode!(%{
          "id" => "or_123",
          "model" => "openai/gpt-5.2",
          "choices" => [
            %{
              "finish_reason" => "stop",
              "message" => %{
                "content" => "Phoenix update",
                "annotations" => [
                  %{
                    "type" => "url_citation",
                    "url_citation" => %{
                      "url" => "https://example.com/source-b",
                      "title" => "Source B",
                      "content" => "Snippet",
                      "start_index" => 0,
                      "end_index" => 7
                    }
                  }
                ]
              }
            }
          ],
          "usage" => %{"prompt_tokens" => 11, "completion_tokens" => 6, "total_tokens" => 17}
        })
      )
    end)

    assert {:ok, response} =
             OpenRouter.web_search("latest phoenix news",
               model: "openai/gpt-5.2",
               engine: "native",
               max_results: 3
             )

    assert response.content == "Phoenix update"

    assert [%{url: "https://example.com/source-b", title: "Source B", snippet: "Snippet"}] =
             response.citations

    assert response.usage.total_tokens == 17
  end

  test "web_search/2 returns rate limit metadata on 429" do
    bypass = Bypass.open()
    original_base_url = Application.get_env(:assistant, :openrouter_base_url)
    original_api_key = Application.get_env(:assistant, :openrouter_api_key)

    Application.put_env(
      :assistant,
      :openrouter_base_url,
      "http://127.0.0.1:#{bypass.port}/api/v1"
    )

    Application.put_env(:assistant, :openrouter_api_key, "test-openrouter-key")

    on_exit(fn ->
      if original_base_url,
        do: Application.put_env(:assistant, :openrouter_base_url, original_base_url),
        else: Application.delete_env(:assistant, :openrouter_base_url)

      if original_api_key,
        do: Application.put_env(:assistant, :openrouter_api_key, original_api_key),
        else: Application.delete_env(:assistant, :openrouter_api_key)
    end)

    Bypass.expect_once(bypass, "POST", "/api/v1/chat/completions", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("retry-after", "12")
      |> Plug.Conn.resp(429, Jason.encode!(%{"error" => %{"message" => "rate limited"}}))
    end)

    assert {:error, {:rate_limited, 12}} =
             OpenRouter.web_search("latest phoenix news", model: "openai/gpt-5.2")
  end
end
