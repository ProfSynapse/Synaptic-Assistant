# test/assistant/skills/memory/handlers_test.exs — Smoke tests for memory skill handlers.
#
# Verifies all 7 handler modules compile, implement the Handler behaviour,
# and handle missing required parameters correctly.

defmodule Assistant.Skills.Memory.HandlersTest do
  use Assistant.DataCase, async: true

  alias Assistant.Skills.Context
  alias Assistant.Skills.Memory.{
    Save,
    Search,
    Get,
    ExtractEntities,
    CloseRelation,
    QueryEntityGraph,
    CompactConversation
  }
  alias Assistant.Skills.Result

  @handlers [Save, Search, Get, ExtractEntities, CloseRelation, QueryEntityGraph, CompactConversation]

  defp build_context do
    %Context{
      conversation_id: Ecto.UUID.generate(),
      execution_id: Ecto.UUID.generate(),
      user_id: Ecto.UUID.generate()
    }
  end

  describe "module compilation and behaviour" do
    test "all handler modules are loaded" do
      for handler <- @handlers do
        assert Code.ensure_loaded?(handler),
               "#{inspect(handler)} should be loaded"
      end
    end

    test "all handlers export execute/2" do
      for handler <- @handlers do
        assert function_exported?(handler, :execute, 2),
               "#{inspect(handler)} should export execute/2"
      end
    end
  end

  describe "Save handler" do
    test "returns error for missing content" do
      ctx = build_context()
      assert {:ok, %Result{status: :error}} = Save.execute(%{}, ctx)
    end

    test "creates memory entry with valid content" do
      ctx = build_context()
      # Insert a test user so the FK constraint passes
      user = insert_test_user(ctx.user_id)
      ctx = %{ctx | user_id: user.id}

      assert {:ok, %Result{status: :ok, side_effects: [:memory_saved]}} =
               Save.execute(%{"content" => "Test memory", "tags" => "test,smoke"}, ctx)
    end
  end

  describe "Search handler" do
    test "returns empty results for non-matching query" do
      ctx = build_context()
      user = insert_test_user(ctx.user_id)
      ctx = %{ctx | user_id: user.id}

      assert {:ok, %Result{status: :ok}} =
               Search.execute(%{"query" => "nonexistent-xyzzy"}, ctx)
    end
  end

  describe "Get handler" do
    test "returns error for missing id" do
      ctx = build_context()
      assert {:ok, %Result{status: :error}} = Get.execute(%{}, ctx)
    end

    test "returns error for non-existent entry" do
      ctx = build_context()

      assert {:ok, %Result{status: :error}} =
               Get.execute(%{"id" => Ecto.UUID.generate()}, ctx)
    end
  end

  describe "ExtractEntities handler" do
    test "handles empty entities and relations" do
      ctx = build_context()

      assert {:ok, %Result{status: :ok, side_effects: [:entities_extracted]}} =
               ExtractEntities.execute(%{"entities" => [], "relations" => []}, ctx)
    end
  end

  describe "CloseRelation handler" do
    test "returns error for missing relation_id" do
      ctx = build_context()
      assert {:ok, %Result{status: :error}} = CloseRelation.execute(%{}, ctx)
    end

    test "returns error for non-existent relation" do
      ctx = build_context()

      assert {:ok, %Result{status: :error}} =
               CloseRelation.execute(%{"relation_id" => Ecto.UUID.generate()}, ctx)
    end
  end

  describe "QueryEntityGraph handler" do
    test "returns error for missing entity_name" do
      ctx = build_context()
      assert {:ok, %Result{status: :error}} = QueryEntityGraph.execute(%{}, ctx)
    end

    test "returns empty for non-existent entity" do
      ctx = build_context()
      user = insert_test_user(ctx.user_id)
      ctx = %{ctx | user_id: user.id}

      assert {:ok, %Result{status: :ok}} =
               QueryEntityGraph.execute(%{"entity" => "nonexistent-entity"}, ctx)
    end
  end

  describe "CompactConversation handler" do
    test "returns error for missing conversation_id" do
      ctx = build_context()
      assert {:ok, %Result{status: :error}} = CompactConversation.execute(%{}, ctx)
    end
  end

  # Helper to insert a test user with a specific user_id for FK constraints
  defp insert_test_user(_original_id) do
    alias Assistant.Schemas.User

    %User{}
    |> User.changeset(%{
      external_id: "skill-test-#{System.unique_integer([:positive])}",
      channel: "test"
    })
    |> Repo.insert!()
  end
end
