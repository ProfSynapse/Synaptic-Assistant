defmodule Assistant.Integrations.OpenAITest do
  use ExUnit.Case, async: true

  alias Assistant.Integrations.OpenAI

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
