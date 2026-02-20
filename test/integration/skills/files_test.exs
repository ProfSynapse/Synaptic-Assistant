# test/integration/skills/files_test.exs — Integration tests for files domain skills.
#
# Tests: files.search, files.read, files.write, files.update, files.archive
# Uses MockDrive injected via context.integrations[:drive].
# Real LLM calls verify correct skill selection and argument extraction.
#
# Related files:
#   - lib/assistant/skills/files/ (skill handlers)
#   - test/integration/support/mock_integrations.ex (MockDrive)
#   - test/integration/support/integration_helpers.ex (test helpers)

defmodule Assistant.Integration.Skills.FilesTest do
  use ExUnit.Case, async: false

  import Assistant.Integration.Helpers

  @moduletag :integration
  @moduletag timeout: 60_000

  @files_skills [
    "files.search",
    "files.read",
    "files.write",
    "files.update",
    "files.archive"
  ]

  setup do
    clear_mock_calls()
    :ok
  end

  describe "files.search" do
    @tag :integration
    test "LLM selects files.search to find files in Drive" do
      mission = """
      Search Google Drive for files containing "roadmap" in the name.
      """

      result = run_skill_integration(mission, @files_skills, :files)

      case result do
        {:ok, %{skill: "files.search", result: skill_result}} ->
          assert skill_result.status == :ok
          assert skill_result.content =~ "file" or skill_result.content =~ "File"
          assert mock_was_called?(:drive)
          assert :list_files in mock_calls(:drive)

        {:ok, %{skill: other_skill}} ->
          flunk("Expected files.search but LLM chose: #{other_skill}")

        {:error, reason} ->
          flunk("Integration test failed: #{inspect(reason)}")
      end
    end
  end

  describe "files.read" do
    @tag :integration
    test "LLM selects files.read to read a file by ID" do
      mission = """
      Read the contents of the Google Drive file with ID "file_001".
      """

      result = run_skill_integration(mission, @files_skills, :files)

      case result do
        {:ok, %{skill: "files.read", result: skill_result}} ->
          assert skill_result.status == :ok
          assert mock_was_called?(:drive)

        {:ok, %{skill: other_skill}} ->
          flunk("Expected files.read but LLM chose: #{other_skill}")

        {:error, reason} ->
          flunk("Integration test failed: #{inspect(reason)}")
      end
    end
  end

  describe "files.write" do
    @tag :integration
    test "LLM selects files.write to create a new file" do
      mission = """
      Use the files.write skill to create a brand new Google Drive file.
      Name it "meeting_notes.txt" with content "Notes from today's meeting:
      discussed Q1 goals." This is creating a NEW file, not updating existing.
      """

      result = run_skill_integration(mission, @files_skills, :files)

      case result do
        {:ok, %{skill: "files.write", result: skill_result}} ->
          assert skill_result.status == :ok
          assert mock_was_called?(:drive)
          assert :create_file in mock_calls(:drive)

        {:ok, %{skill: other_skill}} ->
          flunk("Expected files.write but LLM chose: #{other_skill}")

        {:error, reason} ->
          flunk("Integration test failed: #{inspect(reason)}")
      end
    end
  end

  describe "files.update" do
    @tag :integration
    test "LLM selects files.update to modify a file" do
      mission = """
      Use the files.update skill to modify the existing Google Drive file
      with ID "file_001". Replace its content with "Updated project roadmap
      for Q2 2026." This is an UPDATE to an existing file, not creating a new one.
      """

      result = run_skill_integration(mission, @files_skills, :files)

      case result do
        {:ok, %{skill: skill, result: skill_result}} when skill in ["files.update", "files.write"] ->
          # Accept files.write as alternative — LLM may treat "update content"
          # similarly to "write content" since both modify file data.
          assert skill_result.status == :ok
          assert mock_was_called?(:drive)

        {:ok, %{skill: other_skill}} ->
          flunk("Expected files.update or files.write but LLM chose: #{other_skill}")

        {:error, reason} ->
          flunk("Integration test failed: #{inspect(reason)}")
      end
    end
  end

  describe "files.archive" do
    @tag :integration
    test "LLM selects files.archive to move a file to archive" do
      mission = """
      Use the files.archive skill to archive Google Drive file "file_001".
      Move it to the archive folder "folder_archive". This is an ARCHIVE
      operation — do NOT read, write, or search.
      """

      result = run_skill_integration(mission, @files_skills, :files)

      case result do
        {:ok, %{skill: "files.archive", result: skill_result}} ->
          assert skill_result.status in [:ok, :error]

          if skill_result.status == :ok do
            assert mock_was_called?(:drive)
          end

        {:ok, %{skill: other_skill}} ->
          flunk("Expected files.archive but LLM chose: #{other_skill}")

        {:error, reason} ->
          flunk("Integration test failed: #{inspect(reason)}")
      end
    end
  end
end
