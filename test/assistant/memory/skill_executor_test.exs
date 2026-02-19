# test/assistant/memory/skill_executor_test.exs
#
# Tests for the search-first enforcement wrapper. This is a CRITICAL invariant:
# write skills (save_memory, extract_entities, close_relation, compact_conversation)
# require a preceding read skill (search_memories, query_entity_graph) in the
# same dispatch session.

defmodule Assistant.Memory.SkillExecutorTest do
  use ExUnit.Case, async: true

  alias Assistant.Memory.SkillExecutor
  alias Assistant.Skills.{Context, Result}

  # ---------------------------------------------------------------
  # new_session/0
  # ---------------------------------------------------------------

  describe "new_session/0" do
    test "creates session with has_searched = false" do
      session = SkillExecutor.new_session()
      assert session == %{has_searched: false}
    end
  end

  # ---------------------------------------------------------------
  # Skill classification helpers
  # ---------------------------------------------------------------

  describe "read_skill?/1" do
    test "identifies search_memories as read" do
      assert SkillExecutor.read_skill?("memory.search_memories")
    end

    test "identifies query_entity_graph as read" do
      assert SkillExecutor.read_skill?("memory.query_entity_graph")
    end

    test "write skills are not read skills" do
      refute SkillExecutor.read_skill?("memory.save_memory")
      refute SkillExecutor.read_skill?("memory.extract_entities")
      refute SkillExecutor.read_skill?("memory.close_relation")
      refute SkillExecutor.read_skill?("memory.compact_conversation")
    end

    test "non-memory skills are not read skills" do
      refute SkillExecutor.read_skill?("email.send")
    end
  end

  describe "write_skill?/1" do
    test "identifies all write skills" do
      assert SkillExecutor.write_skill?("memory.save_memory")
      assert SkillExecutor.write_skill?("memory.extract_entities")
      assert SkillExecutor.write_skill?("memory.close_relation")
      assert SkillExecutor.write_skill?("memory.compact_conversation")
    end

    test "read skills are not write skills" do
      refute SkillExecutor.write_skill?("memory.search_memories")
      refute SkillExecutor.write_skill?("memory.query_entity_graph")
    end
  end

  describe "memory_skill?/1" do
    test "all memory skills return true" do
      assert SkillExecutor.memory_skill?("memory.search_memories")
      assert SkillExecutor.memory_skill?("memory.query_entity_graph")
      assert SkillExecutor.memory_skill?("memory.save_memory")
      assert SkillExecutor.memory_skill?("memory.extract_entities")
      assert SkillExecutor.memory_skill?("memory.close_relation")
      assert SkillExecutor.memory_skill?("memory.compact_conversation")
    end

    test "non-memory skills return false" do
      refute SkillExecutor.memory_skill?("email.send")
      refute SkillExecutor.memory_skill?("tasks.create")
    end
  end

  # ---------------------------------------------------------------
  # execute/6 — search-first enforcement
  # ---------------------------------------------------------------

  describe "execute/6 — write without prior read" do
    test "save_memory rejected without prior search" do
      session = SkillExecutor.new_session()
      context = build_context()

      assert {:error, :memory_write_without_search, ^session} =
               SkillExecutor.execute("memory.save_memory", nil, %{}, context, session)
    end

    test "extract_entities rejected without prior search" do
      session = SkillExecutor.new_session()
      context = build_context()

      assert {:error, :memory_write_without_search, ^session} =
               SkillExecutor.execute("memory.extract_entities", nil, %{}, context, session)
    end

    test "close_relation rejected without prior search" do
      session = SkillExecutor.new_session()
      context = build_context()

      assert {:error, :memory_write_without_search, ^session} =
               SkillExecutor.execute("memory.close_relation", nil, %{}, context, session)
    end

    test "compact_conversation rejected without prior search" do
      session = SkillExecutor.new_session()
      context = build_context()

      assert {:error, :memory_write_without_search, ^session} =
               SkillExecutor.execute("memory.compact_conversation", nil, %{}, context, session)
    end

    test "session state unchanged after rejection" do
      session = SkillExecutor.new_session()
      context = build_context()

      {:error, :memory_write_without_search, returned_session} =
        SkillExecutor.execute("memory.save_memory", nil, %{}, context, session)

      assert returned_session.has_searched == false
    end
  end

  describe "execute/6 — read sets has_searched flag" do
    test "search_memories with nil handler sets has_searched" do
      session = SkillExecutor.new_session()
      context = build_context()
      assert session.has_searched == false

      assert {:ok, %Result{status: :ok}, updated_session} =
               SkillExecutor.execute("memory.search_memories", nil, %{}, context, session)

      assert updated_session.has_searched == true
    end

    test "query_entity_graph with nil handler sets has_searched" do
      session = SkillExecutor.new_session()
      context = build_context()

      assert {:ok, %Result{}, updated_session} =
               SkillExecutor.execute("memory.query_entity_graph", nil, %{}, context, session)

      assert updated_session.has_searched == true
    end
  end

  describe "execute/6 — write after read succeeds" do
    test "save_memory succeeds after search_memories" do
      session = SkillExecutor.new_session()
      context = build_context()

      # Step 1: Read
      {:ok, _result, session_after_read} =
        SkillExecutor.execute("memory.search_memories", nil, %{}, context, session)

      assert session_after_read.has_searched == true

      # Step 2: Write
      assert {:ok, %Result{status: :ok}, final_session} =
               SkillExecutor.execute("memory.save_memory", nil, %{}, context, session_after_read)

      # has_searched stays true
      assert final_session.has_searched == true
    end

    test "extract_entities succeeds after query_entity_graph" do
      session = SkillExecutor.new_session()
      context = build_context()

      {:ok, _result, session_after_read} =
        SkillExecutor.execute("memory.query_entity_graph", nil, %{}, context, session)

      assert {:ok, %Result{}, _} =
               SkillExecutor.execute("memory.extract_entities", nil, %{}, context, session_after_read)
    end

    test "multiple writes allowed after single read" do
      session = SkillExecutor.new_session()
      context = build_context()

      {:ok, _, s1} = SkillExecutor.execute("memory.search_memories", nil, %{}, context, session)
      {:ok, _, s2} = SkillExecutor.execute("memory.save_memory", nil, %{}, context, s1)
      {:ok, _, s3} = SkillExecutor.execute("memory.extract_entities", nil, %{}, context, s2)
      {:ok, _, _s4} = SkillExecutor.execute("memory.close_relation", nil, %{}, context, s3)
    end
  end

  describe "execute/6 — session reset between missions" do
    test "new_session resets has_searched" do
      session = SkillExecutor.new_session()
      context = build_context()

      # First mission: read + write
      {:ok, _, session_after_read} =
        SkillExecutor.execute("memory.search_memories", nil, %{}, context, session)

      {:ok, _, _} =
        SkillExecutor.execute("memory.save_memory", nil, %{}, context, session_after_read)

      # New mission: reset
      new_session = SkillExecutor.new_session()
      assert new_session.has_searched == false

      # Write should be rejected in new session
      assert {:error, :memory_write_without_search, _} =
               SkillExecutor.execute("memory.save_memory", nil, %{}, context, new_session)
    end
  end

  describe "execute/6 — non-memory skill passthrough" do
    test "non-memory skill with nil handler returns stub result" do
      session = SkillExecutor.new_session()
      context = build_context()

      assert {:ok, %Result{status: :ok}, returned_session} =
               SkillExecutor.execute("email.send", nil, %{}, context, session)

      # has_searched should NOT be set by non-memory skill
      assert returned_session.has_searched == false
    end
  end

  # ---------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------

  defp build_context do
    %Context{
      conversation_id: "test-conv-#{System.unique_integer([:positive])}",
      execution_id: "test-exec-#{System.unique_integer([:positive])}",
      user_id: "test-user"
    }
  end
end
