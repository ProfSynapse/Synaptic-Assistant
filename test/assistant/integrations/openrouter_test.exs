# test/assistant/integrations/openrouter_test.exs
#
# Tests for the OpenRouter LLM client.
# Covers public pure functions (build_request_body, sort_tools,
# cached_content, audio_content). HTTP-dependent paths (chat_completion,
# streaming_completion) are tested only for the error/no-model path
# since no Mox/Bypass is available in the dependency tree.

defmodule Assistant.Integrations.OpenRouterTest do
  use ExUnit.Case, async: true

  alias Assistant.Integrations.OpenRouter

  # ---------------------------------------------------------------
  # build_request_body/2
  # ---------------------------------------------------------------

  describe "build_request_body/2" do
    test "returns error when no model specified" do
      messages = [%{role: "user", content: "Hello"}]
      assert {:error, :no_model_specified} = OpenRouter.build_request_body(messages, [])
    end

    test "builds minimal body with model and messages" do
      messages = [%{role: "user", content: "Hello"}]
      assert {:ok, body} = OpenRouter.build_request_body(messages, model: "test/model")

      assert body.model == "test/model"
      assert body.messages == messages
      refute Map.has_key?(body, :tools)
      refute Map.has_key?(body, :tool_choice)
      refute Map.has_key?(body, :temperature)
      refute Map.has_key?(body, :max_tokens)
    end

    test "includes tools and auto tool_choice when tools provided" do
      messages = [%{role: "user", content: "Hello"}]
      tools = [%{type: "function", function: %{name: "test_tool"}}]

      assert {:ok, body} = OpenRouter.build_request_body(messages, model: "test/model", tools: tools)

      assert is_list(body.tools)
      assert body.tool_choice == "auto"
    end

    test "does not add tools when tools list is empty" do
      messages = [%{role: "user", content: "Hello"}]
      assert {:ok, body} = OpenRouter.build_request_body(messages, model: "test/model", tools: [])

      refute Map.has_key?(body, :tools)
      refute Map.has_key?(body, :tool_choice)
    end

    test "allows explicit tool_choice override" do
      messages = [%{role: "user", content: "Hello"}]
      tools = [%{type: "function", function: %{name: "test"}}]

      assert {:ok, body} =
               OpenRouter.build_request_body(messages,
                 model: "test/model",
                 tools: tools,
                 tool_choice: "required"
               )

      assert body.tool_choice == "required"
    end

    test "includes temperature when specified" do
      messages = [%{role: "user", content: "Hello"}]
      assert {:ok, body} = OpenRouter.build_request_body(messages, model: "test/model", temperature: 0.5)
      assert body.temperature == 0.5
    end

    test "includes max_tokens when specified" do
      messages = [%{role: "user", content: "Hello"}]
      assert {:ok, body} = OpenRouter.build_request_body(messages, model: "test/model", max_tokens: 4096)
      assert body.max_tokens == 4096
    end

    test "includes parallel_tool_calls when specified" do
      messages = [%{role: "user", content: "Hello"}]

      assert {:ok, body} =
               OpenRouter.build_request_body(messages,
                 model: "test/model",
                 parallel_tool_calls: true
               )

      assert body.parallel_tool_calls == true
    end

    test "sorts tools alphabetically by function name" do
      messages = [%{role: "user", content: "Hello"}]

      tools = [
        %{type: "function", function: %{name: "zebra_tool"}},
        %{type: "function", function: %{name: "alpha_tool"}},
        %{type: "function", function: %{name: "middle_tool"}}
      ]

      assert {:ok, body} = OpenRouter.build_request_body(messages, model: "test/model", tools: tools)

      names = Enum.map(body.tools, fn t -> t.function.name end)
      assert names == ["alpha_tool", "middle_tool", "zebra_tool"]
    end
  end

  # ---------------------------------------------------------------
  # sort_tools/1
  # ---------------------------------------------------------------

  describe "sort_tools/1" do
    test "sorts by atom-keyed function name" do
      tools = [
        %{function: %{name: "z_tool"}},
        %{function: %{name: "a_tool"}}
      ]

      sorted = OpenRouter.sort_tools(tools)
      assert [%{function: %{name: "a_tool"}}, %{function: %{name: "z_tool"}}] = sorted
    end

    test "sorts by string-keyed function name" do
      tools = [
        %{"function" => %{"name" => "z_tool"}},
        %{"function" => %{"name" => "a_tool"}}
      ]

      sorted = OpenRouter.sort_tools(tools)
      assert [%{"function" => %{"name" => "a_tool"}}, %{"function" => %{"name" => "z_tool"}}] = sorted
    end

    test "handles empty list" do
      assert [] = OpenRouter.sort_tools([])
    end

    test "handles single tool" do
      tools = [%{function: %{name: "only_tool"}}]
      assert ^tools = OpenRouter.sort_tools(tools)
    end

    test "handles mixed key types" do
      tools = [
        %{function: %{name: "beta"}},
        %{"function" => %{"name" => "alpha"}}
      ]

      sorted = OpenRouter.sort_tools(tools)
      names = Enum.map(sorted, fn
        %{function: %{name: n}} -> n
        %{"function" => %{"name" => n}} -> n
      end)

      assert names == ["alpha", "beta"]
    end
  end

  # ---------------------------------------------------------------
  # cached_content/2
  # ---------------------------------------------------------------

  describe "cached_content/2" do
    test "creates cache content with default TTL" do
      result = OpenRouter.cached_content("System prompt text")

      assert result.type == "text"
      assert result.text == "System prompt text"
      assert result.cache_control == %{type: "ephemeral"}
    end

    test "creates cache content with custom TTL" do
      result = OpenRouter.cached_content("System prompt text", ttl: "1h")

      assert result.type == "text"
      assert result.text == "System prompt text"
      assert result.cache_control == %{type: "ephemeral", ttl: "1h"}
    end
  end

  # ---------------------------------------------------------------
  # audio_content/2
  # ---------------------------------------------------------------

  describe "audio_content/2" do
    test "creates audio content part" do
      result = OpenRouter.audio_content("base64data==", "wav")

      assert result.type == "input_audio"
      assert result.input_audio.data == "base64data=="
      assert result.input_audio.format == "wav"
    end

    test "supports different audio formats" do
      for format <- ["wav", "mp3", "ogg", "flac"] do
        result = OpenRouter.audio_content("data", format)
        assert result.input_audio.format == format
      end
    end
  end

  # ---------------------------------------------------------------
  # chat_completion/2 — error paths
  # ---------------------------------------------------------------

  describe "chat_completion/2" do
    test "returns error when no model specified" do
      messages = [%{role: "user", content: "Hello"}]
      assert {:error, :no_model_specified} = OpenRouter.chat_completion(messages)
    end
  end
end
