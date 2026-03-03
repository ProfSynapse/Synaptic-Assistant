# test/assistant/analytics/trajectory_exporter_test.exs — Tests for JSONL
# trajectory export I/O.

defmodule Assistant.Analytics.TrajectoryExporterTest do
  use ExUnit.Case, async: true

  alias Assistant.Analytics.TrajectoryExporter

  @test_base_path "tmp/test_trajectories"

  setup do
    # Clean up test directory before each test
    File.rm_rf!(@test_base_path)
    Application.put_env(:assistant, :trajectories_base_path, @test_base_path)

    on_exit(fn ->
      File.rm_rf!(@test_base_path)
      Application.delete_env(:assistant, :trajectories_base_path)
    end)

    :ok
  end

  describe "export_turn/1" do
    test "writes a JSONL line to the correct path" do
      attrs = %{
        conversation_id: "conv-test-1",
        user_id: "user-test-1",
        user_message: "Hello",
        assistant_response: "Hi!",
        messages: [
          %{role: "user", content: "Hello"},
          %{role: "assistant", content: "Hi!"}
        ],
        usage: %{prompt_tokens: 10, completion_tokens: 5}
      }

      assert :ok = TrajectoryExporter.export_turn(attrs)

      path = TrajectoryExporter.trajectory_path("user-test-1", "conv-test-1")
      assert File.exists?(path)

      content = File.read!(path)
      lines = String.split(content, "\n", trim: true)
      assert length(lines) == 1

      {:ok, entry} = Jason.decode(hd(lines))
      assert entry["type"] == "turn"
      assert entry["conversation_id"] == "conv-test-1"
      assert entry["user_message"] == "Hello"
      assert entry["assistant_response"] == "Hi!"
    end

    test "appends multiple turns to the same file" do
      for i <- 1..3 do
        attrs = %{
          conversation_id: "conv-append",
          user_id: "user-append",
          user_message: "Message #{i}",
          assistant_response: "Response #{i}",
          messages: []
        }

        assert :ok = TrajectoryExporter.export_turn(attrs)
      end

      path = TrajectoryExporter.trajectory_path("user-append", "conv-append")
      content = File.read!(path)
      lines = String.split(content, "\n", trim: true)
      assert length(lines) == 3
    end

    test "handles nil gracefully without crashing" do
      assert :ok = TrajectoryExporter.export_turn(%{})
    end
  end

  describe "trajectory_path/2" do
    test "builds path with user and conversation segments" do
      path = TrajectoryExporter.trajectory_path("user-1", "conv-2")
      assert path =~ "user-1"
      assert path =~ "conv-2.jsonl"
    end

    test "sanitizes unsafe path segments" do
      path = TrajectoryExporter.trajectory_path("../evil", "../../etc/passwd")
      refute path =~ ".."
      # Path.join adds forward slashes — that's expected.
      # Sanitization removes ../ traversal and absolute paths, not path separators.
      assert path =~ "___evil"
    end
  end
end
