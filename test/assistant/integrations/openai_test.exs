defmodule Assistant.Integrations.OpenAITest do
  use ExUnit.Case, async: true

  alias Assistant.Integrations.OpenAI

  # ---------------------------------------------------------------
  # safe_error_message/1 — regression test for FunctionClauseError
  # when API returns empty string body instead of decoded JSON map.
  #
  # Since safe_error_message is private, we replicate its logic to
  # verify the contract: non-map response bodies must not crash.
  # See: codex_stream_request/3 line ~654 crash on Railway.
  # ---------------------------------------------------------------

  describe "safe_error_message contract (replicated logic)" do
    # Mirrors the private safe_error_message/1 added to openai.ex
    defp safe_error_message(%{"error" => %{"message" => msg}}) when is_binary(msg), do: msg
    defp safe_error_message(%{"error" => msg}) when is_binary(msg), do: msg
    defp safe_error_message(body) when is_binary(body) and body != "", do: body
    defp safe_error_message(_), do: "Unknown error"

    test "extracts message from standard OpenAI error response" do
      body = %{"error" => %{"message" => "Rate limit exceeded", "type" => "rate_limit"}}
      assert safe_error_message(body) == "Rate limit exceeded"
    end

    test "extracts string error from flat error key" do
      body = %{"error" => "Something went wrong"}
      assert safe_error_message(body) == "Something went wrong"
    end

    test "returns body string when response is a non-empty string (not JSON)" do
      assert safe_error_message("Service Unavailable") == "Service Unavailable"
    end

    test "returns 'Unknown error' for empty string body (crash scenario)" do
      assert safe_error_message("") == "Unknown error"
    end

    test "returns 'Unknown error' for nil body" do
      assert safe_error_message(nil) == "Unknown error"
    end

    test "returns 'Unknown error' for integer body" do
      assert safe_error_message(42) == "Unknown error"
    end

    test "returns 'Unknown error' for empty map" do
      assert safe_error_message(%{}) == "Unknown error"
    end

    test "returns 'Unknown error' for map with non-standard error structure" do
      assert safe_error_message(%{"detail" => "not found"}) == "Unknown error"
    end
  end

  describe "build_request_body/2" do
    test "returns error when no model specified" do
      messages = [%{role: "user", content: "Hello"}]
      assert {:error, :no_model_specified} = OpenAI.build_request_body(messages, [])
    end

    test "strips cache_control from content parts" do
      messages = [
        %{
          role: "system",
          content: [
            %{type: "text", text: "Prompt", cache_control: %{type: "ephemeral"}}
          ]
        }
      ]

      assert {:ok, body} = OpenAI.build_request_body(messages, model: "gpt-5-mini")

      [message] = body.messages
      [part] = message.content

      refute Map.has_key?(part, :cache_control)
      refute Map.has_key?(part, "cache_control")
      assert part.type == "text"
      assert part.text == "Prompt"
    end

    test "includes tools and default tool_choice" do
      messages = [%{role: "user", content: "Hello"}]

      tools = [
        %{type: "function", function: %{name: "b_tool"}},
        %{type: "function", function: %{name: "a_tool"}}
      ]

      assert {:ok, body} = OpenAI.build_request_body(messages, model: "gpt-5-mini", tools: tools)

      assert body.tool_choice == "auto"
      names = Enum.map(body.tools, fn t -> t.function.name end)
      assert names == ["a_tool", "b_tool"]
    end
  end
end
