defmodule Assistant.Encryption.Context do
  @moduledoc false

  @aad_version 1

  @spec normalize(Assistant.Encryption.field_ref()) :: map()
  def normalize(field_ref) when is_map(field_ref) do
    %{
      billing_account_id: fetch!(field_ref, :billing_account_id),
      table: field_ref |> fetch!(:table) |> to_string(),
      field: field_ref |> fetch!(:field) |> to_string(),
      row_id: Map.get(field_ref, :row_id),
      version: Map.get(field_ref, :version, 1)
    }
  end

  @spec aad_version() :: pos_integer()
  def aad_version, do: @aad_version

  @spec derivation_context(Assistant.Encryption.field_ref()) :: String.t()
  def derivation_context(field_ref) do
    field_ref
    |> normalize()
    |> then(fn %{
                 billing_account_id: billing_account_id,
                 table: table,
                 field: field,
                 version: version
               } ->
      "billing_account:#{billing_account_id}|table:#{table}|field:#{field}|v#{version}"
    end)
    |> Base.encode64()
  end

  @spec aad(Assistant.Encryption.field_ref()) :: binary()
  def aad(field_ref) do
    field_ref
    |> normalize()
    |> Map.put(:aad_version, @aad_version)
    |> Jason.encode!()
  end

  defp fetch!(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} when is_binary(value) or is_atom(value) ->
        value

      {:ok, value} ->
        raise ArgumentError, "invalid encryption context field #{inspect(key)}: #{inspect(value)}"

      :error ->
        raise ArgumentError, "missing encryption context field #{inspect(key)}"
    end
  end
end
