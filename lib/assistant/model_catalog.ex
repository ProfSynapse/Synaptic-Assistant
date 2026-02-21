defmodule Assistant.ModelCatalog do
  @moduledoc """
  File-backed model catalog overrides for settings UI add/edit flows.
  """

  alias Assistant.Config.Loader, as: ConfigLoader

  @default_catalog_path "config/model_catalog.json"

  @type model_entry :: %{
          id: String.t(),
          name: String.t(),
          input_cost: String.t(),
          output_cost: String.t(),
          max_context_tokens: String.t()
        }

  @spec list_models() :: [map()]
  def list_models do
    base_models =
      try do
        ConfigLoader.all_models()
        |> Enum.map(&normalize_base_model/1)
      rescue
        _ -> []
      end

    %{models: overrides, removed_ids: removed_ids} = read_catalog()

    merged =
      base_models
      |> Enum.reject(&MapSet.member?(removed_ids, &1.id))
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
              output_cost: existing.output_cost || model.output_cost,
              max_context_tokens: existing.max_context_tokens || model.max_context_tokens
            }
          end
        )
      end)

    merged
    |> Map.values()
    |> Enum.sort_by(&String.downcase(&1.name || &1.id))
  end

  @doc """
  Returns all model IDs currently in the catalog (after merge/removal rules).
  """
  @spec catalog_model_ids() :: MapSet.t(String.t())
  def catalog_model_ids do
    list_models()
    |> Enum.map(& &1.id)
    |> MapSet.new()
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
    model = normalize_attrs(attrs)

    model_id = model.id
    name = model.name
    input_cost = model.input_cost
    output_cost = model.output_cost
    max_context_tokens = model.max_context_tokens

    cond do
      model_id == "" ->
        {:error, :missing_id}

      name == "" ->
        {:error, :missing_name}

      input_cost == "" ->
        {:error, :missing_input_cost}

      output_cost == "" ->
        {:error, :missing_output_cost}

      max_context_tokens == "" ->
        {:error, :missing_max_context_tokens}

      true ->
        persist_model(model)
    end
  end

  @doc """
  Adds or updates a model in the catalog and ensures it isn't marked removed.
  """
  @spec add_model(map()) :: {:ok, model_entry()} | {:error, term()}
  def add_model(attrs) when is_map(attrs) do
    case upsert_model(attrs) do
      {:ok, model} ->
        {:ok, model}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Removes a model from the catalog.

  For base config models this hides them via `removed_model_ids`.
  For user-added models this deletes the override entry.
  """
  @spec remove_model(String.t()) :: :ok | {:error, term()}
  def remove_model(model_id) when is_binary(model_id) do
    normalized_id = String.trim(model_id)

    if normalized_id == "" do
      {:error, :missing_id}
    else
      %{models: overrides, removed_ids: removed_ids} = read_catalog()
      updated_overrides = Map.delete(overrides, normalized_id)
      updated_removed_ids = MapSet.put(removed_ids, normalized_id)

      case write_catalog(updated_overrides, updated_removed_ids) do
        :ok -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  def remove_model(_), do: {:error, :missing_id}

  defp persist_model(model) do
    %{models: overrides, removed_ids: removed_ids} = read_catalog()
    updated_overrides = Map.put(overrides, model.id, model)
    updated_removed_ids = MapSet.delete(removed_ids, model.id)

    case write_catalog(updated_overrides, updated_removed_ids) do
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
      output_cost: output_cost,
      max_context_tokens: model.max_context_tokens || "n/a"
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

  defp normalize_attrs(attrs) when is_map(attrs) do
    %{
      id: attrs["id"] |> to_string() |> String.trim(),
      name: attrs["name"] |> to_string() |> String.trim(),
      input_cost:
        attrs["input_cost"]
        |> to_string()
        |> String.trim()
        |> blank_to_default("n/a"),
      output_cost:
        attrs["output_cost"]
        |> to_string()
        |> String.trim()
        |> blank_to_default("n/a"),
      max_context_tokens:
        attrs["max_context_tokens"]
        |> to_string()
        |> String.trim()
        |> blank_to_default("n/a")
    }
  end

  defp blank_to_default("", default), do: default
  defp blank_to_default(value, _default), do: value

  defp read_catalog do
    path = catalog_path()

    if File.exists?(path) do
      with {:ok, content} <- File.read(path),
           {:ok, decoded} <- Jason.decode(content) do
        parse_catalog(decoded)
      else
        _ -> %{models: %{}, removed_ids: MapSet.new()}
      end
    else
      %{models: %{}, removed_ids: MapSet.new()}
    end
  end

  defp parse_catalog(decoded) when is_map(decoded) do
    models =
      decoded
      |> Map.get("models", [])
      |> case do
        list when is_list(list) ->
          Map.new(list, fn model ->
            id = to_string(model["id"] || "")

            {id,
             %{
               id: id,
               name: to_string(model["name"] || id),
               input_cost: to_string(model["input_cost"] || "n/a"),
               output_cost: to_string(model["output_cost"] || "n/a"),
               max_context_tokens: to_string(model["max_context_tokens"] || "n/a")
             }}
          end)

        _ ->
          %{}
      end

    removed_ids =
      decoded
      |> Map.get("removed_model_ids", [])
      |> case do
        ids when is_list(ids) ->
          ids
          |> Enum.map(&to_string/1)
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))
          |> MapSet.new()

        _ ->
          MapSet.new()
      end

    %{models: models, removed_ids: removed_ids}
  end

  defp parse_catalog(_), do: %{models: %{}, removed_ids: MapSet.new()}

  defp write_catalog(overrides, removed_ids) do
    path = catalog_path()
    File.mkdir_p!(Path.dirname(path))

    payload =
      Jason.encode_to_iodata!(
        %{
          models: Map.values(overrides),
          removed_model_ids: removed_ids |> MapSet.to_list() |> Enum.sort()
        },
        pretty: true
      )

    File.write(path, payload)
  end

  defp catalog_path do
    Application.get_env(:assistant, :model_catalog_path, @default_catalog_path)
  end
end
