# test/integration/skills/workflow_test.exs — Integration tests for workflow domain skills.
#
# Tests: workflow.list, workflow.create, workflow.run, workflow.cancel
# Workflow skills operate on local files (priv/workflows/). The list and create
# skills read/write markdown files; run and cancel interact with the scheduler.
# Real LLM calls verify correct skill selection and argument extraction.
#
# Related files:
#   - lib/assistant/skills/workflow/ (skill handlers)
#   - test/integration/support/integration_helpers.ex (test helpers)

defmodule Assistant.Integration.Skills.WorkflowTest do
  use ExUnit.Case, async: false

  import Assistant.Integration.Helpers

  @moduletag :integration
  @moduletag timeout: 60_000

  @workflow_skills [
    "workflow.list",
    "workflow.create",
    "workflow.run",
    "workflow.cancel"
  ]

  setup do
    clear_mock_calls()
    :ok
  end

  describe "workflow.list" do
    @tag :integration
    test "LLM selects workflow.list to show available workflows" do
      mission = """
      List all available workflows.
      """

      result = run_skill_integration(mission, @workflow_skills, :workflow)

      case result do
        {:ok, %{skill: "workflow.list", result: skill_result}} ->
          # May return ok with empty list or with workflows
          assert skill_result.status == :ok

        {:ok, %{skill: other_skill}} ->
          flunk("Expected workflow.list but LLM chose: #{other_skill}")

        {:error, reason} ->
          flunk("Integration test failed: #{inspect(reason)}")
      end
    end
  end

  describe "workflow.create" do
    @tag :integration
    test "LLM selects workflow.create to create a new workflow" do
      mission = """
      Create a new workflow called "morning-briefing" with description
      "Daily morning news and weather briefing" and prompt
      "Give me a morning briefing with today's top news and weather."
      """

      result = run_skill_integration(mission, @workflow_skills, :workflow)

      case result do
        {:ok, %{skill: "workflow.create", result: skill_result}} ->
          # May succeed or fail depending on filesystem permissions
          assert skill_result.status in [:ok, :error]

          # Clean up if created
          if skill_result.status == :ok do
            cleanup_workflow("morning-briefing")
          end

        {:ok, %{skill: other_skill}} ->
          flunk("Expected workflow.create but LLM chose: #{other_skill}")

        {:error, reason} ->
          flunk("Integration test failed: #{inspect(reason)}")
      end
    end
  end

  describe "workflow.run" do
    @tag :integration
    test "LLM selects workflow.run to execute a workflow" do
      mission = """
      Run the workflow named "daily-report".
      """

      result = run_skill_integration(mission, @workflow_skills, :workflow)

      case result do
        {:ok, %{skill: "workflow.run", result: skill_result}} ->
          # May fail if workflow doesn't exist; that's expected
          assert skill_result.status in [:ok, :error]

        {:ok, %{skill: other_skill}} ->
          flunk("Expected workflow.run but LLM chose: #{other_skill}")

        {:error, reason} ->
          flunk("Integration test failed: #{inspect(reason)}")
      end
    end
  end

  describe "workflow.cancel" do
    @tag :integration
    test "LLM selects workflow.cancel to stop a scheduled workflow" do
      mission = """
      Cancel the scheduled workflow named "daily-report".
      """

      result = run_skill_integration(mission, @workflow_skills, :workflow)

      case result do
        {:ok, %{skill: "workflow.cancel", result: skill_result}} ->
          # May fail if no such workflow is scheduled; that's expected
          assert skill_result.status in [:ok, :error]

        {:ok, %{skill: other_skill}} ->
          flunk("Expected workflow.cancel but LLM chose: #{other_skill}")

        {:error, reason} ->
          flunk("Integration test failed: #{inspect(reason)}")
      end
    end
  end

  # -------------------------------------------------------------------
  # Cleanup helpers
  # -------------------------------------------------------------------

  defp cleanup_workflow(name) do
    dir = Application.get_env(:assistant, :workflows_dir, "priv/workflows")
    path = Path.join(dir, "#{name}.md")
    File.rm(path)
  end
end
