# test/assistant/memory/file_cache_worker_test.exs — Tests for FileCacheWorker Oban job.

defmodule Assistant.Memory.FileCacheWorkerTest do
  use ExUnit.Case, async: true

  alias Assistant.Memory.FileCacheWorker

  describe "module compilation" do
    test "FileCacheWorker is loaded and exports Oban.Worker callbacks" do
      assert Code.ensure_loaded?(FileCacheWorker)
      assert function_exported?(FileCacheWorker, :perform, 1)
      assert function_exported?(FileCacheWorker, :new, 1)
    end
  end

  describe "new/1 changeset" do
    test "builds a valid Oban job changeset" do
      changeset =
        FileCacheWorker.new(%{
          user_id: "user-123",
          file_path: "docs/readme.md",
          content: "# Hello\n\nThis is a readme file."
        })

      assert %Ecto.Changeset{} = changeset
      assert changeset.valid?
    end
  end
end
