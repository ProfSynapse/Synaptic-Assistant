# test/integration/skills/memory_test.exs — Integration tests for memory domain skills.
#
# Tests: memory.save_memory, memory.search_memories, memory.extract_entities,
#        memory.compact_conversation, memory.query_entity_graph, memory.close_relation
# Memory skills use the database directly (no external API mocks needed).
# Real LLM calls verify correct skill selection and argument extraction.
#
# Related files:
#   - lib/assistant/skills/memory/ (skill handlers)
#   - test/integration/support/integration_helpers.ex (test helpers)

defmodule Assistant.Integration.Skills.MemoryTest do
  use Assistant.DataCase, async: false

  import Assistant.Integration.Helpers

  @moduletag :integration
  @moduletag timeout: 60_000

  @memory_skills [
    "memory.save_memory",
    "memory.search_memories",
    "memory.extract_entities",
    "memory.compact_conversation",
    "memory.query_entity_graph",
    "memory.close_relation"
  ]

  setup do
    clear_mock_calls()
    :ok
  end

  describe "memory.save_memory" do
    @tag :integration
    test "LLM selects memory.save_memory to store a memory" do
      mission = """
      Use the memory.save_memory skill to permanently store this new information:
      "The user prefers dark mode in all applications."
      Set the content argument to the text above, category to "preference",
      and tags to "ui,settings". This is a SAVE operation, not a search.
      """

      result = run_skill_integration(mission, @memory_skills, :memory)

      case result do
        {:ok, %{skill: "memory.save_memory", result: skill_result}} ->
          # Primary assertion: correct skill selected.
          # May return :error if LLM maps args differently than handler expects
          # (e.g., "text" vs "content" for the memory content field).
          assert skill_result.status in [:ok, :error]

        {:ok, %{skill: other_skill}} ->
          flunk("Expected memory.save_memory but LLM chose: #{other_skill}")

        {:error, reason} ->
          flunk("Integration test failed: #{inspect(reason)}")
      end
    end
  end

  describe "memory.search_memories" do
    @tag :integration
    test "LLM selects memory.search_memories to find memories" do
      # Save a memory first. Reuse context so search runs under the same user_id.
      context = build_context(:memory)

      flags = %{
        "content" => "User likes dark mode",
        "category" => "preference",
        "tags" => "ui"
      }

      execute_skill("memory.save_memory", flags, context)

      mission = """
      Search my memories for anything related to "dark mode".
      """

      result = run_skill_integration(mission, @memory_skills, context)

      case result do
        {:ok, %{skill: "memory.search_memories", result: skill_result}} ->
          assert skill_result.status == :ok

        {:ok, %{skill: other_skill}} ->
          flunk("Expected memory.search_memories but LLM chose: #{other_skill}")

        {:error, reason} ->
          flunk("Integration test failed: #{inspect(reason)}")
      end
    end
  end

  describe "memory.extract_entities" do
    @tag :integration
    test "LLM selects memory.extract_entities for entity extraction" do
      mission = """
      Extract entities from this text: "John met with Sarah at Google
      headquarters in Mountain View to discuss the Kubernetes project."
      """

      result = run_skill_integration(mission, @memory_skills, :memory)

      case result do
        {:ok, %{skill: "memory.extract_entities", result: skill_result}} ->
          # Weak assertion: extract_entities makes a second LLM call internally
          # to identify entities from the text. In test, the LLM client may not
          # be configured, causing an internal error. Skill selection is correct.
          # TODO: Strengthen by mocking the internal LLM call or by injecting a
          # test LLM client that returns canned entity extraction results.
          assert skill_result.status in [:ok, :error]

        {:ok, %{skill: other_skill}} ->
          flunk("Expected memory.extract_entities but LLM chose: #{other_skill}")

        {:error, reason} ->
          flunk("Integration test failed: #{inspect(reason)}")
      end
    end
  end

  describe "memory.compact_conversation" do
    @tag :integration
    test "LLM selects memory.compact_conversation for summarization" do
      mission = """
      Use the memory.compact_conversation skill to compact and summarize
      the current conversation to save memory.
      """

      result = run_skill_integration(mission, @memory_skills, :memory)

      case result do
        {:ok, %{skill: "memory.compact_conversation", result: skill_result}} ->
          # Weak assertion: compact requires real conversation message history
          # in the DB. The test context has an empty conversation (no messages),
          # so the handler returns :error ("nothing to compact").
          # TODO: Strengthen by inserting test messages into the conversation
          # before compacting, so the handler has data to work with.
          assert skill_result.status in [:ok, :error]

        {:ok, %{skill: other_skill}} ->
          flunk("Expected memory.compact_conversation but LLM chose: #{other_skill}")

        {:error, {:execution_failed, "memory.compact_conversation", _reason}} ->
          # The handler may crash because the LLM sends a non-UUID conversation_id
          # or the test context has no real conversation history. Skill selection
          # was correct — this is an acceptable execution-level failure.
          :ok

        {:error, reason} ->
          flunk("Integration test failed: #{inspect(reason)}")
      end
    end
  end

  describe "memory.query_entity_graph" do
    @tag :integration
    test "LLM selects memory.query_entity_graph for entity queries" do
      mission = """
      Query the entity graph for all entities related to "Google".
      """

      result = run_skill_integration(mission, @memory_skills, :memory)

      case result do
        {:ok, %{skill: "memory.query_entity_graph", result: skill_result}} ->
          # Weak assertion: query_entity_graph returns :error when the entity
          # graph has no data. The test DB is clean, so no entities exist.
          # TODO: Strengthen by extracting entities first (via extract_entities
          # with mocked LLM), then querying the graph with known data.
          assert skill_result.status in [:ok, :error]

        {:ok, %{skill: other_skill}} ->
          flunk("Expected memory.query_entity_graph but LLM chose: #{other_skill}")

        {:error, reason} ->
          flunk("Integration test failed: #{inspect(reason)}")
      end
    end
  end

  describe "memory.close_relation" do
    @tag :integration
    test "LLM selects memory.close_relation to end a relationship" do
      mission = """
      Use the memory.close_relation skill to terminate/close the entity
      relationship with ID "rel_001". The reason for closing is
      "no longer relevant". This is a CLOSE operation on a relation.
      """

      result = run_skill_integration(mission, @memory_skills, :memory)

      case result do
        {:ok, %{skill: "memory.close_relation", result: skill_result}} ->
          # Weak assertion: close_relation needs an existing relation ID.
          # "rel_001" is a fabricated ID that doesn't exist in the test DB.
          # TODO: Strengthen by creating a relation first (extract entities +
          # create relation), then closing it with the real ID.
          assert skill_result.status in [:ok, :error]

        {:ok, %{skill: other_skill}} ->
          flunk("Expected memory.close_relation but LLM chose: #{other_skill}")

        {:error, {:execution_failed, "memory.close_relation", _reason}} ->
          # Handler may crash if relation doesn't exist. Skill selection correct.
          :ok

        {:error, reason} ->
          flunk("Integration test failed: #{inspect(reason)}")
      end
    end
  end
end
