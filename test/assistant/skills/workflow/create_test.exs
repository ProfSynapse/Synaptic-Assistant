# test/assistant/skills/workflow/create_test.exs
#
# Tests for the workflow.create skill handler. Uses a temporary directory
# for workflow file creation to avoid affecting the real priv/workflows/.
# Tests name validation, cron validation, file generation, and conflict detection.
#
# NOTE: The r-backend fix changes validator returns to {:error, message}
# which the `with` chain propagates directly. Tests match that pattern.

defmodule Assistant.Skills.Workflow.CreateTest do
  use ExUnit.Case, async: false

  alias Assistant.Skills.Workflow.Create
  alias Assistant.Skills.Context
  alias Assistant.Skills.Result

  # ---------------------------------------------------------------
  # Setup — temp directory for workflow files
  # ---------------------------------------------------------------

  setup do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "workflow_create_test_#{:erlang.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp_dir)
    Application.put_env(:assistant, :workflows_dir, tmp_dir)

    on_exit(fn ->
      Application.delete_env(:assistant, :workflows_dir)
      File.rm_rf!(tmp_dir)
    end)

    %{workflows_dir: tmp_dir}
  end

  defp build_context do
    %Context{
      conversation_id: "conv-1",
      execution_id: "exec-1",
      user_id: "user-1",
      integrations: %{}
    }
  end

  defp valid_flags do
    %{
      "name" => "daily-report",
      "description" => "Generate daily summary report",
      "prompt" => "Summarize today's activity and create a report."
    }
  end

  # ---------------------------------------------------------------
  # Happy path
  # ---------------------------------------------------------------

  describe "execute/2 happy path" do
    test "creates workflow file and returns success", %{workflows_dir: dir} do
      {:ok, result} = Create.execute(valid_flags(), build_context())

      assert result.status == :ok
      assert result.content =~ "daily-report"
      assert result.content =~ dir
      assert result.side_effects == [:workflow_created]
      assert result.metadata.workflow_name == "daily-report"
    end

    test "writes file with correct frontmatter", %{workflows_dir: dir} do
      Create.execute(valid_flags(), build_context())

      path = Path.join(dir, "daily-report.md")
      assert File.exists?(path)

      content = File.read!(path)
      assert content =~ ~s(name: "daily-report")
      assert content =~ ~s(description: "Generate daily summary report")
      assert content =~ "Summarize today's activity"
    end

    test "includes cron in frontmatter when provided", %{workflows_dir: dir} do
      flags = Map.put(valid_flags(), "cron", "0 8 * * *")
      Create.execute(flags, build_context())

      path = Path.join(dir, "daily-report.md")
      content = File.read!(path)
      assert content =~ ~s(cron: "0 8 * * *")
    end

    test "includes schedule in success message when cron provided" do
      flags = Map.put(valid_flags(), "cron", "0 8 * * *")
      {:ok, result} = Create.execute(flags, build_context())

      assert result.content =~ "Schedule: 0 8 * * *"
    end

    test "includes channel in frontmatter when provided", %{workflows_dir: dir} do
      flags = Map.put(valid_flags(), "channel", "spaces/ABC123")
      Create.execute(flags, build_context())

      path = Path.join(dir, "daily-report.md")
      content = File.read!(path)
      assert content =~ ~s(channel: "spaces/ABC123")
    end

    test "includes tags in frontmatter", %{workflows_dir: dir} do
      Create.execute(valid_flags(), build_context())

      path = Path.join(dir, "daily-report.md")
      content = File.read!(path)
      assert content =~ "- workflow"
      assert content =~ "- scheduled"
    end
  end

  # ---------------------------------------------------------------
  # Missing required flags
  # ---------------------------------------------------------------

  describe "execute/2 missing required flags" do
    test "returns error when --name is missing" do
      flags = Map.delete(valid_flags(), "name")
      result = Create.execute(flags, build_context())

      assert {:ok, %Result{status: :error, content: content}} = result
      assert content =~ "name"
    end

    test "returns error when --description is missing" do
      flags = Map.delete(valid_flags(), "description")
      result = Create.execute(flags, build_context())

      assert {:ok, %Result{status: :error, content: content}} = result
      assert content =~ "description"
    end

    test "returns error when --prompt is missing" do
      flags = Map.delete(valid_flags(), "prompt")
      result = Create.execute(flags, build_context())

      assert {:ok, %Result{status: :error, content: content}} = result
      assert content =~ "prompt"
    end

    test "lists all missing flags" do
      result = Create.execute(%{}, build_context())

      assert {:ok, %Result{status: :error, content: content}} = result
      assert content =~ "name"
      assert content =~ "description"
      assert content =~ "prompt"
    end
  end

  # ---------------------------------------------------------------
  # Name validation
  # ---------------------------------------------------------------

  describe "execute/2 name validation" do
    test "rejects uppercase names" do
      flags = Map.put(valid_flags(), "name", "DailyReport")
      result = Create.execute(flags, build_context())

      assert {:ok, %Result{status: :error, content: content}} = result
      assert content =~ "lowercase"
    end

    test "rejects names starting with number" do
      flags = Map.put(valid_flags(), "name", "1report")
      result = Create.execute(flags, build_context())

      assert {:ok, %Result{status: :error, content: content}} = result
      assert content =~ "lowercase"
    end

    test "rejects names with spaces" do
      flags = Map.put(valid_flags(), "name", "daily report")
      result = Create.execute(flags, build_context())

      assert {:ok, %Result{status: :error, content: content}} = result
      assert content =~ "lowercase"
    end

    test "rejects names with special characters" do
      flags = Map.put(valid_flags(), "name", "daily@report")
      result = Create.execute(flags, build_context())

      assert {:ok, %Result{status: :error, content: content}} = result
      assert content =~ "lowercase"
    end

    test "accepts lowercase with hyphens" do
      flags = Map.put(valid_flags(), "name", "daily-report")
      {:ok, result} = Create.execute(flags, build_context())
      assert result.status == :ok
    end

    test "accepts lowercase with underscores" do
      flags = Map.put(valid_flags(), "name", "daily_report")
      {:ok, result} = Create.execute(flags, build_context())
      assert result.status == :ok
    end

    test "accepts lowercase with numbers" do
      flags = Map.put(valid_flags(), "name", "report2")
      {:ok, result} = Create.execute(flags, build_context())
      assert result.status == :ok
    end
  end

  # ---------------------------------------------------------------
  # Cron validation
  # ---------------------------------------------------------------

  describe "execute/2 cron validation" do
    test "accepts valid cron expression" do
      flags = Map.put(valid_flags(), "cron", "0 8 * * *")
      {:ok, result} = Create.execute(flags, build_context())
      assert result.status == :ok
    end

    test "accepts cron without --cron flag" do
      {:ok, result} = Create.execute(valid_flags(), build_context())
      assert result.status == :ok
    end

    test "rejects invalid cron expression" do
      flags = Map.put(valid_flags(), "cron", "not-a-cron")
      result = Create.execute(flags, build_context())

      assert {:ok, %Result{status: :error, content: content}} = result
      assert content =~ "Invalid cron expression"
    end
  end

  # ---------------------------------------------------------------
  # YAML injection prevention (validate_no_newlines)
  # ---------------------------------------------------------------

  describe "execute/2 YAML injection prevention" do
    test "rejects newline in description" do
      flags = Map.put(valid_flags(), "description", "legit\nevil_key: injected")
      result = Create.execute(flags, build_context())

      assert {:ok, %Result{status: :error, content: content}} = result
      assert content =~ "description"
      assert content =~ "newlines"
    end

    test "rejects carriage return in description" do
      flags = Map.put(valid_flags(), "description", "legit\revil_key: injected")
      result = Create.execute(flags, build_context())

      assert {:ok, %Result{status: :error, content: content}} = result
      assert content =~ "description"
      assert content =~ "newlines"
    end

    test "rejects newline in channel" do
      flags = Map.put(valid_flags(), "channel", "spaces/ABC\nevil_key: injected")
      result = Create.execute(flags, build_context())

      assert {:ok, %Result{status: :error, content: content}} = result
      assert content =~ "channel"
      assert content =~ "newlines"
    end

    test "rejects carriage return in channel" do
      flags = Map.put(valid_flags(), "channel", "spaces/ABC\revil_key: injected")
      result = Create.execute(flags, build_context())

      assert {:ok, %Result{status: :error, content: content}} = result
      assert content =~ "channel"
      assert content =~ "newlines"
    end

    test "accepts description without newlines" do
      {:ok, result} = Create.execute(valid_flags(), build_context())
      assert result.status == :ok
    end

    test "accepts channel without newlines" do
      flags = Map.put(valid_flags(), "channel", "spaces/ABC123")
      {:ok, result} = Create.execute(flags, build_context())
      assert result.status == :ok
    end
  end

  # ---------------------------------------------------------------
  # Conflict detection
  # ---------------------------------------------------------------

  describe "execute/2 conflict detection" do
    test "rejects duplicate workflow name", %{workflows_dir: dir} do
      # Create first workflow
      Create.execute(valid_flags(), build_context())
      assert File.exists?(Path.join(dir, "daily-report.md"))

      # Try to create duplicate
      result = Create.execute(valid_flags(), build_context())

      assert {:ok, %Result{status: :error, content: content}} = result
      assert content =~ "already exists"
    end
  end
end
