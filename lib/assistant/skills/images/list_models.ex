# lib/assistant/skills/images/list_models.ex — Handler for images.list_models skill.
#
# Lists image-generation models from the assistant model roster in config.yaml.
# Supports optional tier filtering for quick model selection.

defmodule Assistant.Skills.Images.ListModels do
  @moduledoc """
  Skill handler for listing configured image-generation models.

  Reads the model roster via `Assistant.Config.Loader.all_models/0` and filters
  to models that include the `:image_generation` use case.
  """

  @behaviour Assistant.Skills.Handler

  alias Assistant.Config.Loader, as: ConfigLoader
  alias Assistant.Skills.Result

  @valid_tiers ~w(primary balanced fast cheap)

  @impl true
  def execute(flags, context) do
    catalog = Map.get(context.integrations, :model_catalog, ConfigLoader)
    tier = normalize_tier(flags["tier"])

    with {:ok, models} <- fetch_image_models(catalog),
         {:ok, filtered} <- maybe_filter_by_tier(models, tier) do
      {:ok,
       %Result{
         status: :ok,
         content: format_models(filtered, tier),
         metadata: %{
           count: length(filtered),
           tier: tier,
           model_ids: Enum.map(filtered, & &1.id)
         }
       }}
    else
      {:error, message} ->
        {:ok, %Result{status: :error, content: message}}
    end
  end

  defp normalize_tier(nil), do: nil
  defp normalize_tier(""), do: nil
  defp normalize_tier(tier) when is_binary(tier), do: String.downcase(String.trim(tier))
  defp normalize_tier(_), do: nil

  defp fetch_image_models(catalog) do
    models = catalog.all_models()

    filtered =
      Enum.filter(models, fn model ->
        is_map(model) and :image_generation in (model.use_cases || [])
      end)

    case filtered do
      [] ->
        {:error,
         "No image generation models are configured. Add models with use_cases: [image_generation] in config/config.yaml."}

      _ ->
        {:ok, filtered}
    end
  rescue
    error ->
      {:error, "Could not load model roster: #{Exception.message(error)}"}
  end

  defp maybe_filter_by_tier(models, nil), do: {:ok, models}

  defp maybe_filter_by_tier(models, tier) do
    if tier in @valid_tiers do
      filtered = Enum.filter(models, fn model -> Atom.to_string(model.tier) == tier end)
      {:ok, filtered}
    else
      {:error, "Invalid --tier value: #{tier}. Valid tiers: #{Enum.join(@valid_tiers, ", ")}."}
    end
  end

  defp format_models([], tier) when is_binary(tier) do
    "No image models found for tier: #{tier}."
  end

  defp format_models(models, tier) do
    header =
      if tier do
        "Configured image models (tier: #{tier}):"
      else
        "Configured image models:"
      end

    lines =
      Enum.map(models, fn model ->
        "- #{model.id} (tier: #{model.tier}, cost: #{model.cost_tier}) — #{model.description}"
      end)

    Enum.join([header | lines], "\n")
  end
end
