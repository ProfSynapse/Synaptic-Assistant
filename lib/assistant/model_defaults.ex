defmodule Assistant.ModelDefaults do
  @moduledoc """
  File-backed default model selections by role.
  """

  @default_path "config/model_defaults.json"

  @spec list_defaults() :: map()
  def list_defaults do
    path = defaults_path()

    if File.exists?(path) do
      with {:ok, content} <- File.read(path),
           {:ok, decoded} <- Jason.decode(content),
           defaults when is_map(defaults) <- decoded["defaults"] do
        defaults
        |> Enum.reduce(%{}, fn {role, model_id}, acc ->
          role_key = role |> to_string() |> String.trim()
          model_value = model_id |> to_string() |> String.trim()

          if role_key == "" do
            acc
          else
            Map.put(acc, role_key, model_value)
          end
        end)
      else
        _ -> %{}
      end
    else
      %{}
    end
  end

  @spec default_model_id(atom()) :: String.t() | nil
  def default_model_id(role) when is_atom(role) do
    list_defaults()
    |> Map.get(Atom.to_string(role))
    |> case do
      "" -> nil
      value -> value
    end
  end

  @spec save_defaults(map()) :: :ok | {:error, term()}
  def save_defaults(params) when is_map(params) do
    sanitized =
      params
      |> Enum.reduce(%{}, fn {role, model_id}, acc ->
        role_key = role |> to_string() |> String.trim()
        model_value = model_id |> to_string() |> String.trim()

        cond do
          role_key == "" -> acc
          true -> Map.put(acc, role_key, model_value)
        end
      end)

    path = defaults_path()
    File.mkdir_p!(Path.dirname(path))
    payload = Jason.encode_to_iodata!(%{"defaults" => sanitized}, pretty: true)
    File.write(path, payload)
  end

  defp defaults_path do
    Application.get_env(:assistant, :model_defaults_path, @default_path)
  end
end
