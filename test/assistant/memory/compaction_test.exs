# test/assistant/memory/compaction_test.exs — Behavioral tests for Memory.Compaction.
#
# Tests the compact/2 pipeline with real DB fixtures (conversations + messages)
# and the Config.Loader ETS table. The LLM call (OpenRouter) will fail because
# no real HTTP client is configured, which exercises the error recovery path.
#
# For the "no new messages" path, we create a conversation with zero messages.

defmodule Assistant.Memory.CompactionTest do
  use Assistant.DataCase, async: false
  # async: false because we use named ETS tables (Config.Loader, PromptLoader)

  alias Assistant.Memory.Compaction
  alias Assistant.Schemas.{Conversation, Message, User}

  setup do
    ensure_config_loader_started()
    ensure_prompt_loader_started()

    # Create a test user for FK constraints
    user =
      %User{}
      |> User.changeset(%{
        external_id: "compaction-test-#{System.unique_integer([:positive])}",
        channel: "test"
      })
      |> Repo.insert!()

    %{user: user}
  end

  # ---------------------------------------------------------------
  # compact/2 — no new messages
  # ---------------------------------------------------------------

  describe "compact/2 with no new messages" do
    test "returns {:error, :no_new_messages} for conversation with zero messages", %{user: user} do
      {:ok, conversation} =
        %Conversation{}
        |> Conversation.changeset(%{channel: "test", user_id: user.id})
        |> Repo.insert()

      assert {:error, :no_new_messages} = Compaction.compact(conversation.id)
    end
  end

  # ---------------------------------------------------------------
  # compact/2 — conversation not found
  # ---------------------------------------------------------------

  describe "compact/2 with non-existent conversation" do
    test "returns {:error, :not_found}" do
      fake_id = Ecto.UUID.generate()
      assert {:error, :not_found} = Compaction.compact(fake_id)
    end
  end

  # ---------------------------------------------------------------
  # compact/2 — first-run (summary_version == 0) with messages
  # ---------------------------------------------------------------

  describe "compact/2 first-run with messages" do
    test "fetches messages and attempts LLM call (fails without real client)", %{user: user} do
      {:ok, conversation} =
        %Conversation{}
        |> Conversation.changeset(%{channel: "test", user_id: user.id})
        |> Repo.insert()

      # Insert some messages
      for {role, content} <- [{"user", "Hello"}, {"assistant", "Hi there"}, {"user", "How are you?"}] do
        %Message{}
        |> Message.changeset(%{
          conversation_id: conversation.id,
          role: role,
          content: content
        })
        |> Repo.insert!()
      end

      # compact/2 will find messages, resolve config model, and then fail at the
      # OpenRouter HTTP call (no real client). The error will be from the LLM layer.
      result = Compaction.compact(conversation.id)

      # Should be an error from the LLM call or prompt rendering, NOT :no_new_messages
      assert {:error, reason} = result
      assert reason != :no_new_messages
      assert reason != :not_found
    end
  end

  # ---------------------------------------------------------------
  # compact/2 — incremental (summary_version > 0) with messages
  # ---------------------------------------------------------------

  describe "compact/2 incremental with existing summary" do
    test "fetches recent messages for incremental fold", %{user: user} do
      {:ok, conversation} =
        %Conversation{}
        |> Conversation.changeset(%{
          channel: "test",
          user_id: user.id,
          summary: "Prior summary: user discussed weather.",
          summary_version: 1
        })
        |> Repo.insert()

      # Insert new messages (after the "prior summary")
      for {role, content} <- [{"user", "What about tomorrow?"}, {"assistant", "Rain expected."}] do
        %Message{}
        |> Message.changeset(%{
          conversation_id: conversation.id,
          role: role,
          content: content
        })
        |> Repo.insert!()
      end

      result = Compaction.compact(conversation.id)

      # Should proceed past message fetching (not :no_new_messages) and fail at LLM
      assert {:error, reason} = result
      assert reason != :no_new_messages
      assert reason != :not_found
    end
  end

  # ---------------------------------------------------------------
  # compact/2 — custom opts
  # ---------------------------------------------------------------

  describe "compact/2 with custom options" do
    test "accepts :token_budget and :message_limit opts", %{user: user} do
      {:ok, conversation} =
        %Conversation{}
        |> Conversation.changeset(%{channel: "test", user_id: user.id})
        |> Repo.insert()

      %Message{}
      |> Message.changeset(%{
        conversation_id: conversation.id,
        role: "user",
        content: "Test message"
      })
      |> Repo.insert!()

      # Should not crash with custom opts
      result = Compaction.compact(conversation.id, token_budget: 1024, message_limit: 10)
      assert {:error, _reason} = result
    end
  end

  # ---------------------------------------------------------------
  # Module API
  # ---------------------------------------------------------------

  describe "module API" do
    test "compact/1 and compact/2 are exported" do
      assert function_exported?(Compaction, :compact, 1)
      assert function_exported?(Compaction, :compact, 2)
    end
  end

  # ---------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------

  defp ensure_config_loader_started do
    if :ets.whereis(:assistant_config) != :undefined do
      :ok
    else
      tmp_dir = System.tmp_dir!()
      config_path = Path.join(tmp_dir, "test_config_compaction_#{System.unique_integer([:positive])}.yaml")

      yaml = """
      defaults:
        orchestrator: primary
        compaction: fast

      models:
        - id: "test/fast"
          tier: fast
          description: "test model for compaction"
          use_cases: [orchestrator, compaction]
          supports_tools: true
          max_context_tokens: 100000
          cost_tier: low

      http:
        max_retries: 1
        base_backoff_ms: 100
        max_backoff_ms: 1000
        request_timeout_ms: 5000
        streaming_timeout_ms: 10000

      limits:
        context_utilization_target: 0.85
        compaction_trigger_threshold: 0.75
        response_reserve_tokens: 1024
        orchestrator_turn_limit: 10
        sub_agent_turn_limit: 5
        cache_ttl_seconds: 60
        orchestrator_cache_breakpoints: 2
        sub_agent_cache_breakpoints: 1
      """

      File.write!(config_path, yaml)

      case Assistant.Config.Loader.start_link(path: config_path) do
        {:ok, _} -> :ok
        {:error, {:already_started, _}} -> :ok
      end
    end
  end

  defp ensure_prompt_loader_started do
    if :ets.whereis(:assistant_prompts) != :undefined do
      :ok
    else
      tmp_dir = Path.join(System.tmp_dir!(), "prompts_compaction_#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp_dir)

      File.write!(Path.join(tmp_dir, "compaction.yaml"), """
      system: |
        You are a conversation compactor (test mode).
        Target token budget: <%= @token_budget %>
        Date: <%= @current_date %>
      """)

      case Assistant.Config.PromptLoader.start_link(dir: tmp_dir) do
        {:ok, _} -> :ok
        {:error, {:already_started, _}} -> :ok
      end
    end
  end
end
