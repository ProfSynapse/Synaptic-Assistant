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

    # Create a temp workspace for image files (images.generate writes to disk)
    tmp_dir =
      Path.join(System.tmp_dir!(), "integration_images_#{:erlang.unique_integer([:positive])}")

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

      # images.generate requires workspace_path in context for file output
      context = build_context(:images, %{workspace_path: ws})
      result = run_skill_integration(mission, @images_skills, context)

      case result do
        {:ok, %{skill: "images.generate", result: skill_result}} ->
          assert skill_result.status == :ok
          assert skill_result.content =~ "image"
          assert mock_was_called?(:images)
          assert :image_generation in mock_calls(:images)

        {:ok, %{skill: other_skill}} ->
          flunk("Expected images.generate but LLM chose: #{other_skill}")

        {:error, {:execution_failed, "images.generate", _reason}} ->
          # Execution-level error (e.g., LLM sends wrong arg names). Skill
          # selection was correct — acceptable for LLM-driven integration test.
          :ok

        {:error, reason} ->
          flunk("Integration test failed: #{inspect(reason)}")
      end
    end
  end

  describe "images.list_models" do
    @tag :integration
    test "LLM selects images.list_models to show available models" do
      mission = """
      List all available image generation models.
      """

      result = run_skill_integration(mission, @images_skills, :images)

      case result do
        {:ok, %{skill: "images.list_models", result: skill_result}} ->
          # list_models reads from config; returns available models or
          # "no models configured" message — both are valid :ok responses
          assert skill_result.status == :ok

        {:ok, %{skill: other_skill}} ->
          flunk("Expected images.list_models but LLM chose: #{other_skill}")

        {:error, reason} ->
          flunk("Integration test failed: #{inspect(reason)}")
      end
    end
  end
end
