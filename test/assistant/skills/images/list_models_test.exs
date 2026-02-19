# test/assistant/skills/images/list_models_test.exs
#
# Tests for images.list_models skill handler.

defmodule Assistant.Skills.Images.ListModelsTest do
  use ExUnit.Case, async: true

  alias Assistant.Skills.Context
  alias Assistant.Skills.Images.ListModels
  alias Assistant.Skills.Result

  defmodule MockModelCatalog do
    @moduledoc false

    def all_models do
      [
        %{
          id: "openai/gpt-5-image",
          tier: :primary,
          description: "High quality image generation",
          use_cases: [:image_generation],
          supports_tools: false,
          max_context_tokens: 400_000,
          cost_tier: :high
        },
        %{
          id: "openai/gpt-5-image-mini",
          tier: :balanced,
          description: "Lower-cost image generation",
          use_cases: [:image_generation],
          supports_tools: false,
          max_context_tokens: 400_000,
          cost_tier: :medium
        },
        %{
          id: "openai/gpt-5.2",
          tier: :primary,
          description: "General-purpose text model",
          use_cases: [:orchestrator],
          supports_tools: true,
          max_context_tokens: 400_000,
          cost_tier: :high
        }
      ]
    end
  end

  defmodule EmptyModelCatalog do
    @moduledoc false
    def all_models, do: []
  end

  defp build_context(overrides \\ %{}) do
    base = %Context{
      conversation_id: "conv-1",
      execution_id: "exec-1",
      user_id: "user-1",
      integrations: %{model_catalog: MockModelCatalog}
    }

    Map.merge(base, overrides)
  end

  describe "execute/2 default listing" do
    test "lists configured image models only" do
      {:ok, %Result{status: :ok, content: content, metadata: metadata}} =
        ListModels.execute(%{}, build_context())

      assert content =~ "Configured image models"
      assert content =~ "openai/gpt-5-image"
      assert content =~ "openai/gpt-5-image-mini"
      refute content =~ "openai/gpt-5.2"
      assert metadata.count == 2
    end
  end

  describe "execute/2 tier filtering" do
    test "filters by tier when valid" do
      {:ok, %Result{status: :ok, content: content, metadata: metadata}} =
        ListModels.execute(%{"tier" => "balanced"}, build_context())

      assert content =~ "tier: balanced"
      assert content =~ "openai/gpt-5-image-mini"
      refute content =~ "openai/gpt-5-image (tier: primary"
      assert metadata.count == 1
      assert metadata.tier == "balanced"
    end

    test "returns error for invalid tier" do
      {:ok, %Result{status: :error, content: content}} =
        ListModels.execute(%{"tier" => "premium"}, build_context())

      assert content =~ "Invalid --tier"
    end
  end

  describe "execute/2 with no image models" do
    test "returns error when no image models are configured" do
      context = build_context(%{integrations: %{model_catalog: EmptyModelCatalog}})

      {:ok, %Result{status: :error, content: content}} = ListModels.execute(%{}, context)
      assert content =~ "No image generation models are configured"
    end
  end
end
