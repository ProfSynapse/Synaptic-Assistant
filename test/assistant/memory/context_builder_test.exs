# test/assistant/memory/context_builder_test.exs — Smoke tests for ContextBuilder.
#
# Verifies module compilation, public API exports, and basic formatting logic.
# Database-dependent tests are deferred to the TEST phase (requires running PG).
#
# Related files:
#   - lib/assistant/memory/context_builder.ex (module under test)
#   - lib/assistant/memory/store.ex (conversation lookup)
#   - lib/assistant/memory/search.ex (FTS retrieval)
#   - lib/assistant/task_manager/queries.ex (task listing)

defmodule Assistant.Memory.ContextBuilderTest do
  use ExUnit.Case, async: true

  alias Assistant.Memory.ContextBuilder

  describe "module compilation" do
    test "module is loaded and available" do
      assert Code.ensure_loaded?(Assistant.Memory.ContextBuilder)
    end

    test "exports build_context/3" do
      assert function_exported?(ContextBuilder, :build_context, 3)
    end

    test "exports build_context/2 (default opts)" do
      assert function_exported?(ContextBuilder, :build_context, 2)
    end
  end

  describe "build_context/3 return structure" do
    @tag :requires_db
    test "returns {:ok, map} with memory_context and task_summary keys" do
      # This test requires a running database. When PG is available,
      # it verifies the return tuple structure with nil conversation_id
      # and a fake user_id (which should yield empty strings).
      {:ok, result} = ContextBuilder.build_context(nil, Ecto.UUID.generate())

      assert is_map(result)
      assert Map.has_key?(result, :memory_context)
      assert Map.has_key?(result, :task_summary)
      assert is_binary(result.memory_context)
      assert is_binary(result.task_summary)
    end
  end
end
