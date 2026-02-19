# test/assistant/skills/images/generate_test.exs
#
# Tests for the images.generate skill handler. Uses a mock OpenRouter module
# injected via context.integrations[:openrouter] to avoid real API calls.

defmodule Assistant.Skills.Images.GenerateTest do
  use ExUnit.Case, async: true

  alias Assistant.Skills.Context
  alias Assistant.Skills.Images.Generate
  alias Assistant.Skills.Result

  defmodule MockOpenRouter do
    @moduledoc false

    def image_generation(prompt, opts \\ []) do
      send(self(), {:openrouter_image_generation, prompt, opts})

      case Process.get(:mock_openrouter_response) do
        nil ->
          {:ok,
           %{
             model: "openai/gpt-5-image-mini",
             content: "Image generated successfully.",
             finish_reason: "stop",
             usage: %{total_tokens: 123},
             images: [
               %{
                 url: "data:image/png;base64,#{Base.encode64("fake-png-bytes")}",
                 mime_type: "image/png"
               }
             ]
           }}

        response ->
          response
      end
    end
  end

  defp build_context(overrides \\ %{}) do
    workspace_path =
      Path.join(System.tmp_dir!(), "images_skill_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(workspace_path)

    on_exit(fn -> File.rm_rf!(workspace_path) end)

    base = %Context{
      conversation_id: "conv-1",
      execution_id: "exec-1",
      user_id: "user-1",
      workspace_path: workspace_path,
      integrations: %{openrouter: MockOpenRouter}
    }

    Map.merge(base, overrides)
  end

  describe "execute/2 validation" do
    test "returns error when prompt is missing" do
      {:ok, %Result{status: :error, content: content}} = Generate.execute(%{}, build_context())

      assert content =~ "--prompt"
    end

    test "returns error for invalid n" do
      {:ok, %Result{status: :error, content: content}} =
        Generate.execute(%{"prompt" => "A robot chef", "n" => "0"}, build_context())

      assert content =~ "--n"
    end
  end

  describe "execute/2 success path" do
    test "passes prompt and options to OpenRouter integration" do
      flags = %{
        "prompt" => "A robot chef cooking ramen in Tokyo",
        "model" => "openai/gpt-5-image-mini",
        "n" => "2",
        "size" => "1024x1024",
        "aspect_ratio" => "1:1"
      }

      {:ok, %Result{status: :ok}} = Generate.execute(flags, build_context())

      assert_received {:openrouter_image_generation, "A robot chef cooking ramen in Tokyo", opts}
      assert Keyword.get(opts, :model) == "openai/gpt-5-image-mini"
      assert Keyword.get(opts, :n) == 2
      assert Keyword.get(opts, :size) == "1024x1024"
      assert Keyword.get(opts, :aspect_ratio) == "1:1"
    end

    test "writes data URL image output to file" do
      {:ok, %Result{status: :ok, files_produced: files, metadata: metadata} = result} =
        Generate.execute(%{"prompt" => "A lighthouse in a storm"}, build_context())

      assert length(files) == 1
      [file] = files
      assert File.exists?(file.path)
      assert file.mime_type == "image/png"
      assert metadata.image_count == 1
      assert metadata.saved_paths == [file.path]
      assert result.side_effects == [:image_generated]
    end

    test "keeps remote URLs when image is not a data URL" do
      Process.put(
        :mock_openrouter_response,
        {:ok,
         %{
           model: "openai/gpt-5-image-mini",
           content: nil,
           finish_reason: "stop",
           usage: %{total_tokens: 50},
           images: [%{url: "https://cdn.example.com/image-1.png", mime_type: "image/png"}]
         }}
      )

      {:ok, %Result{status: :ok, files_produced: files, metadata: metadata}} =
        Generate.execute(%{"prompt" => "A city skyline"}, build_context())

      assert files == []
      assert metadata.remote_urls == ["https://cdn.example.com/image-1.png"]
    end
  end

  describe "execute/2 error handling" do
    test "returns error when OpenRouter returns failure" do
      Process.put(:mock_openrouter_response, {:error, {:api_error, 500, "boom"}})

      {:ok, %Result{status: :error, content: content}} =
        Generate.execute(%{"prompt" => "A moon base"}, build_context())

      assert content =~ "Image generation failed"
    end

    test "returns error when response has no images" do
      Process.put(
        :mock_openrouter_response,
        {:ok,
         %{
           model: "openai/gpt-5-image-mini",
           content: "No image",
           finish_reason: "stop",
           usage: %{total_tokens: 20},
           images: []
         }}
      )

      {:ok, %Result{status: :error, content: content}} =
        Generate.execute(%{"prompt" => "A moon base"}, build_context())

      assert content =~ "returned no images"
    end
  end
end
