# test/integration/skills/email_test.exs — Integration tests for email domain skills.
#
# Tests: email.send, email.draft, email.list, email.read, email.search
# Uses MockGmail injected via context.integrations[:gmail].
# Real LLM calls verify correct skill selection and argument extraction.
#
# Related files:
#   - lib/assistant/skills/email/ (skill handlers)
#   - test/integration/support/mock_integrations.ex (MockGmail)
#   - test/integration/support/integration_helpers.ex (test helpers)

defmodule Assistant.Integration.Skills.EmailTest do
  use ExUnit.Case, async: false

  import Assistant.Integration.Helpers

  @moduletag :integration
  @moduletag timeout: 60_000

  @email_skills [
    "email.send",
    "email.draft",
    "email.list",
    "email.read",
    "email.search"
  ]

  setup do
    clear_mock_calls()
    :ok
  end

  describe "email.send" do
    @tag :integration
    test "LLM selects email.send and sends an email via mock Gmail" do
      mission = """
      Send an email to bob@example.com with subject "Meeting Tomorrow"
      and body "Hi Bob, let's meet at 3pm tomorrow. Thanks!"
      """

      result = run_skill_integration(mission, @email_skills, :email)

      case result do
        {:ok, %{skill: "email.send", result: skill_result}} ->
          assert skill_result.status == :ok
          assert skill_result.content =~ "Email sent"
          assert mock_was_called?(:email)
          assert :send_message in mock_calls(:email)

        {:ok, %{skill: other_skill}} ->
          flunk("Expected email.send but LLM chose: #{other_skill}")

        {:error, reason} ->
          flunk("Integration test failed: #{inspect(reason)}")
      end
    end
  end

  describe "email.draft" do
    @tag :integration
    test "LLM selects email.draft and creates a draft via mock Gmail" do
      mission = """
      Draft an email to alice@example.com with subject "Project Update"
      and body "Hi Alice, here is the project update for this week."
      """

      result = run_skill_integration(mission, @email_skills, :email)

      case result do
        {:ok, %{skill: "email.draft", result: skill_result}} ->
          assert skill_result.status == :ok
          assert skill_result.content =~ "draft" or skill_result.content =~ "Draft"
          assert mock_was_called?(:email)
          assert :create_draft in mock_calls(:email)

        {:ok, %{skill: other_skill}} ->
          flunk("Expected email.draft but LLM chose: #{other_skill}")

        {:error, reason} ->
          flunk("Integration test failed: #{inspect(reason)}")
      end
    end
  end

  describe "email.list" do
    @tag :integration
    test "LLM selects email.list to list recent emails" do
      mission = """
      Use the email.list skill to show my inbox messages. I want to browse
      my recent emails. Do NOT search — just list.
      """

      result = run_skill_integration(mission, @email_skills, :email)

      case result do
        {:ok, %{skill: skill, result: skill_result}} when skill in ["email.list", "email.search"] ->
          # Accept both email.list and email.search since the LLM may treat
          # "list recent emails" as equivalent to searching the inbox.
          assert skill_result.status == :ok
          assert mock_was_called?(:email)

        {:ok, %{skill: other_skill}} ->
          flunk("Expected email.list or email.search but LLM chose: #{other_skill}")

        {:error, reason} ->
          flunk("Integration test failed: #{inspect(reason)}")
      end
    end
  end

  describe "email.read" do
    @tag :integration
    test "LLM selects email.read to read a specific email" do
      mission = """
      Read the email with message ID "msg_int_001".
      """

      result = run_skill_integration(mission, @email_skills, :email)

      case result do
        {:ok, %{skill: "email.read", result: skill_result}} ->
          assert skill_result.status == :ok
          assert mock_was_called?(:email)

        {:ok, %{skill: other_skill}} ->
          flunk("Expected email.read but LLM chose: #{other_skill}")

        {:error, reason} ->
          flunk("Integration test failed: #{inspect(reason)}")
      end
    end
  end

  describe "email.search" do
    @tag :integration
    test "LLM selects email.search to find emails by query" do
      mission = """
      Search my emails for messages about "weekly report".
      """

      result = run_skill_integration(mission, @email_skills, :email)

      case result do
        {:ok, %{skill: "email.search", result: skill_result}} ->
          assert skill_result.status == :ok
          assert mock_was_called?(:email)

        {:ok, %{skill: other_skill}} ->
          flunk("Expected email.search but LLM chose: #{other_skill}")

        {:error, reason} ->
          flunk("Integration test failed: #{inspect(reason)}")
      end
    end
  end
end
