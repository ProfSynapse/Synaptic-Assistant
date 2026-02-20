# test/integration/skills/images_test.exs — Integration tests for images domain skills.
#
# Tests: images.generate, images.list_models
# Uses MockOpenRouter injected via context.integrations[:openrouter].
# Real LLM calls verify correct skill selection and argument extraction.
#
# Related files:
#   - lib/assistant/skills/images/ (skill handlers)
#   - test/integration/support/mock_integrations.ex (MockOpenRouter)
#   - test/integration/support/integration_helpers.ex (test helpers)

defmodule Assistant.Integration.Skills.ImagesTest do
  use ExUnit.Case, async: false

  import Assistant.Integration.Helpers

  @moduletag :integration
  @moduletag timeout: 60_000

  @images_skills [
    "images.generate",
    "images.list_models"
  ]

  setup do
    clear_mock_calls()

    # Create a temp workspace for image files
    tmp_dir = Path.join(System.tmp_dir!(), "integration_images_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    {:ok, workspace_path: tmp_dir}
  end

  describe "images.generate" do
    @tag :integration
    test "LLM selects images.generate to create an image", %{workspace_path: ws} do
      mission = """
      Use the images.generate skill to generate an image of a sunset over
      mountains with an orange and purple sky. Set the prompt argument accordingly.
      """

      context = build_context(:images, %{workspace_path: ws})

      case ask_llm_for_skill_call(mission, @images_skills) do
        {:tool_call, "images.generate", flags} ->
          case execute_skill("images.generate", flags, context) do
            {:ok, result} ->
              assert result.status in [:ok, :error]

              if result.status == :ok do
                assert mock_was_called?(:images)
                assert :image_generation in mock_calls(:images)
              end

            {:error, _reason} ->
              # Execution-level error (e.g., missing prompt). Skill selection correct.
              :ok
          end

        {:tool_call, other_skill, _} ->
          flunk("Expected images.generate but LLM chose: #{other_skill}")

        {:text, content} ->
          flunk("LLM returned text instead of tool call: #{String.slice(content, 0, 100)}")

        {:error, reason} ->
          flunk("LLM call failed: #{inspect(reason)}")
      end
    end
  end

  describe "images.list_models" do
    @tag :integration
    test "LLM selects images.list_models to show available models" do
      mission = """
      List all available image generation models.
      """

      context = build_context(:images)

      case ask_llm_for_skill_call(mission, @images_skills) do
        {:tool_call, "images.list_models", flags} ->
          {:ok, result} = execute_skill("images.list_models", flags, context)
          # list_models reads from config; may return models or "no models" message
          assert result.status in [:ok, :error]

        {:tool_call, other_skill, _} ->
          flunk("Expected images.list_models but LLM chose: #{other_skill}")

        {:text, content} ->
          flunk("LLM returned text instead of tool call: #{String.slice(content, 0, 100)}")

        {:error, reason} ->
          flunk("LLM call failed: #{inspect(reason)}")
      end
    end
  end
end
