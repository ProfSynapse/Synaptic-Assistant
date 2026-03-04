defmodule Assistant.Integrations.OpenAIWebSearchTest do
  use ExUnit.Case, async: false

  alias Assistant.Integrations.OpenAI

  test "web_search/2 posts to /responses and returns normalized citations" do
    bypass = Bypass.open()
    original_base_url = Application.get_env(:assistant, :openai_base_url)
    original_api_key = Application.get_env(:assistant, :openai_api_key)

    Application.put_env(:assistant, :openai_base_url, "http://127.0.0.1:#{bypass.port}/v1")
    Application.put_env(:assistant, :openai_api_key, "test-openai-key")

    on_exit(fn ->
      if original_base_url,
        do: Application.put_env(:assistant, :openai_base_url, original_base_url),
        else: Application.delete_env(:assistant, :openai_base_url)

      if original_api_key,
        do: Application.put_env(:assistant, :openai_api_key, original_api_key),
        else: Application.delete_env(:assistant, :openai_api_key)
    end)

    Bypass.expect_once(bypass, "POST", "/v1/responses", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      decoded = Jason.decode!(body)

      assert decoded["tools"] == [%{"type" => "web_search", "external_web_access" => true}]
      assert decoded["include"] == ["web_search_call.action.sources"]
      assert decoded["input"] == "latest elixir news"

      Plug.Conn.resp(
        conn,
        200,
        Jason.encode!(%{
          "id" => "resp_123",
          "model" => "gpt-5.2",
          "status" => "completed",
          "output" => [
            %{
              "type" => "web_search_call",
              "action" => %{
                "sources" => [
                  %{"url" => "https://example.com/source-a", "title" => "Source A"}
                ]
              }
            },
            %{
              "type" => "message",
              "content" => [
                %{
                  "type" => "output_text",
                  "text" => "Elixir update",
                  "annotations" => [
                    %{
                      "type" => "url_citation",
                      "url" => "https://example.com/source-a",
                      "title" => "Source A",
                      "start_index" => 0,
                      "end_index" => 6
                    }
                  ]
                }
              ]
            }
          ],
          "usage" => %{"input_tokens" => 10, "output_tokens" => 5, "total_tokens" => 15}
        })
      )
    end)

    assert {:ok, response} = OpenAI.web_search("latest elixir news", model: "gpt-5.2")
    assert response.content == "Elixir update"
    assert [%{url: "https://example.com/source-a", title: "Source A"}] = response.citations
    assert response.usage.total_tokens == 15
  end

  test "web_search/2 returns rate limit metadata on 429" do
    bypass = Bypass.open()
    original_base_url = Application.get_env(:assistant, :openai_base_url)
    original_api_key = Application.get_env(:assistant, :openai_api_key)

    Application.put_env(:assistant, :openai_base_url, "http://127.0.0.1:#{bypass.port}/v1")
    Application.put_env(:assistant, :openai_api_key, "test-openai-key")

    on_exit(fn ->
      if original_base_url,
        do: Application.put_env(:assistant, :openai_base_url, original_base_url),
        else: Application.delete_env(:assistant, :openai_base_url)

      if original_api_key,
        do: Application.put_env(:assistant, :openai_api_key, original_api_key),
        else: Application.delete_env(:assistant, :openai_api_key)
    end)

    Bypass.expect_once(bypass, "POST", "/v1/responses", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("retry-after", "9")
      |> Plug.Conn.resp(429, Jason.encode!(%{"error" => %{"message" => "slow down"}}))
    end)

    assert {:error, {:rate_limited, 9}} =
             OpenAI.web_search("latest elixir news", model: "gpt-5.2")
  end
end
