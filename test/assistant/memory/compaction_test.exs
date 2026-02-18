# test/assistant/memory/compaction_test.exs — Smoke tests for Memory.Compaction.
#
# Verifies the module compiles and exports the expected public API.
# Full integration tests (with DB + mocked LLM) are deferred to the TEST phase.

defmodule Assistant.Memory.CompactionTest do
  use ExUnit.Case, async: true

  alias Assistant.Memory.Compaction

  describe "module compilation" do
    test "module is loaded and compact/2 is exported" do
      assert function_exported?(Compaction, :compact, 1)
      assert function_exported?(Compaction, :compact, 2)
    end
  end
end
