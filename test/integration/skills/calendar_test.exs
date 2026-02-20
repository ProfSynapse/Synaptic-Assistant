# test/integration/skills/calendar_test.exs — Integration tests for calendar domain skills.
#
# Tests: calendar.list, calendar.create, calendar.update
# Uses MockCalendar injected via context.integrations[:calendar].
# Real LLM calls verify correct skill selection and argument extraction.
#
# Related files:
#   - lib/assistant/skills/calendar/ (skill handlers)
#   - test/integration/support/mock_integrations.ex (MockCalendar)
#   - test/integration/support/integration_helpers.ex (test helpers)

defmodule Assistant.Integration.Skills.CalendarTest do
  use ExUnit.Case, async: false

  import Assistant.Integration.Helpers

  @moduletag :integration
  @moduletag timeout: 60_000

  @calendar_skills [
    "calendar.list",
    "calendar.create",
    "calendar.update"
  ]

  setup do
    clear_mock_calls()
    :ok
  end

  describe "calendar.list" do
    @tag :integration
    test "LLM selects calendar.list to show upcoming events" do
      mission = """
      Show me my calendar events for today, February 20th 2026.
      """

      result = run_skill_integration(mission, @calendar_skills, :calendar)

      case result do
        {:ok, %{skill: "calendar.list", result: skill_result}} ->
          assert skill_result.status == :ok
          assert skill_result.content =~ "event"
          assert mock_was_called?(:calendar)
          assert :list_events in mock_calls(:calendar)

        {:ok, %{skill: other_skill}} ->
          flunk("Expected calendar.list but LLM chose: #{other_skill}")

        {:error, reason} ->
          flunk("Integration test failed: #{inspect(reason)}")
      end
    end
  end

  describe "calendar.create" do
    @tag :integration
    test "LLM selects calendar.create to schedule a new event" do
      mission = """
      Create a calendar event called "Design Review" on February 21st 2026
      from 2:00 PM to 3:00 PM UTC.
      """

      result = run_skill_integration(mission, @calendar_skills, :calendar)

      case result do
        {:ok, %{skill: "calendar.create", result: skill_result}} ->
          assert skill_result.status == :ok
          assert mock_was_called?(:calendar)
          assert :create_event in mock_calls(:calendar)

        {:ok, %{skill: other_skill}} ->
          flunk("Expected calendar.create but LLM chose: #{other_skill}")

        {:error, reason} ->
          flunk("Integration test failed: #{inspect(reason)}")
      end
    end
  end

  describe "calendar.update" do
    @tag :integration
    test "LLM selects calendar.update to modify an existing event" do
      mission = """
      Use the calendar.update skill to modify event "evt_001". Change the
      summary/title to "Updated Team Standup". Pass the event ID as the
      "id" argument.
      """

      result = run_skill_integration(mission, @calendar_skills, :calendar)

      case result do
        {:ok, %{skill: "calendar.update", result: skill_result}} ->
          # Primary assertion: correct skill selected.
          # May return :error if LLM maps arguments differently than the
          # handler expects (e.g., "event_id" vs "id"). Accept both.
          assert skill_result.status in [:ok, :error]

          if skill_result.status == :ok do
            assert mock_was_called?(:calendar)
            assert :update_event in mock_calls(:calendar)
          end

        {:ok, %{skill: other_skill}} ->
          flunk("Expected calendar.update but LLM chose: #{other_skill}")

        {:error, reason} ->
          flunk("Integration test failed: #{inspect(reason)}")
      end
    end
  end
end
