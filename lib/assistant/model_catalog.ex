defmodule Assistant.ModelCatalog do
  @moduledoc """
  File-backed model catalog overrides for settings UI add/edit flows.
  """

  alias Assistant.Config.Loader, as: ConfigLoader

  @default_catalog_path "config/model_catalog.json"

  @spec list_models() :: [map()]
  def list_models do
    base_models =
      try do
        ConfigLoader.all_models()
        |> Enum.map(&normalize_base_model/1)
      rescue
        _ -> []
      end

    overrides = read_overrides()

    merged =
      base_models
      |> Enum.reduce(overrides, fn model, acc ->
        Map.update(
          acc,
          model.id,
          model,
          fn existing ->
            %{
              id: model.id,
              name: existing.name || model.name,
              input_cost: existing.input_cost || model.input_cost,
              output_cost: existing.output_cost || model.output_cost
            }
          end
        )
      end)

    merged
    |> Map.values()
    |> Enum.sort_by(&String.downcase(&1.name || &1.id))
  end

  @spec get_model(String.t()) :: {:ok, map()} | {:error, :not_found}
  def get_model(model_id) when is_binary(model_id) do
    list_models()
    |> Enum.find(&(&1.id == model_id))
    |> case do
      nil -> {:error, :not_found}
      model -> {:ok, model}
    end
  end

  @spec upsert_model(map()) :: {:ok, map()} | {:error, term()}
  def upsert_model(attrs) when is_map(attrs) do
    model_id = attrs["id"] |> to_string() |> String.trim()
    name = attrs["name"] |> to_string() |> String.trim()
    input_cost = attrs["input_cost"] |> to_string() |> String.trim()
    output_cost = attrs["output_cost"] |> to_string() |> String.trim()

    cond do
      model_id == "" ->
        {:error, :missing_id}

      name == "" ->
        {:error, :missing_name}

      input_cost == "" ->
        {:error, :missing_input_cost}

      output_cost == "" ->
        {:error, :missing_output_cost}

      true ->
        persist_model(%{
          id: model_id,
          name: name,
          input_cost: input_cost,
          output_cost: output_cost
        })
    end
  end

  defp persist_model(model) do
    overrides = read_overrides()
    updated = Map.put(overrides, model.id, model)

    case write_overrides(updated) do
      :ok -> {:ok, model}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_base_model(model) do
    {input_cost, output_cost} = infer_costs(model)

    %{
      id: model.id,
      name: model_name(model.id),
      input_cost: input_cost,
      output_cost: output_cost
    }
  end

  defp infer_costs(model) do
    description = to_string(model.description || "")

    case Regex.run(~r/\$(\d+(?:\.\d+)?)\s*\/\s*\$(\d+(?:\.\d+)?)/, description) do
      [_, input, output] ->
        {"$#{input} / 1M tokens", "$#{output} / 1M tokens"}

      _ ->
        case model.cost_tier do
          :low -> {"$0.50 / 1M tokens", "$3.00 / 1M tokens"}
          :medium -> {"$1.50 / 1M tokens", "$6.00 / 1M tokens"}
          :high -> {"$3.00 / 1M tokens", "$15.00 / 1M tokens"}
          _ -> {"n/a", "n/a"}
        end
    end
  end

  defp model_name(id) do
    id
    |> to_string()
    |> String.split("/")
    |> List.last()
    |> String.replace("-", " ")
    |> String.split()
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  defp read_overrides do
    path = catalog_path()

    if File.exists?(path) do
      with {:ok, content} <- File.read(path),
           {:ok, decoded} <- Jason.decode(content),
           models when is_list(models) <- decoded["models"] do
        Map.new(models, fn model ->
          id = to_string(model["id"] || "")

          {id,
           %{
             id: id,
             name: to_string(model["name"] || id),
             input_cost: to_string(model["input_cost"] || "n/a"),
             output_cost: to_string(model["output_cost"] || "n/a")
           }}
        end)
      else
        _ -> %{}
      end
    else
      %{}
    end
  end

  defp write_overrides(overrides) do
    path = catalog_path()
    File.mkdir_p!(Path.dirname(path))
    payload = Jason.encode_to_iodata!(%{models: Map.values(overrides)}, pretty: true)
    File.write(path, payload)
  end

  defp catalog_path do
    Application.get_env(:assistant, :model_catalog_path, @default_catalog_path)
  end
end
