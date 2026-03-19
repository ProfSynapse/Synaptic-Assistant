defmodule Assistant.Encryption.Rewrapper do
  @moduledoc """
  Operator tooling for batch-rewrapping envelope DEKs via Vault Transit.
  """
  import Ecto.Query
  alias Assistant.Repo
  alias Assistant.Encryption.VaultTransitProvider

  require Logger

  @doc """
  Runs a rewrap operation over a specific schema and field.
  Requires picking a mode: :dry_run true (default) runs without writing.

  Example:
      Assistant.Encryption.Rewrapper.rewrap_schema(Assistant.Schemas.Message, :content_encrypted, dry_run: false)
  """
  def rewrap_schema(schema_mod, encrypted_field, opts \\ []) do
    dry_run? = Keyword.get(opts, :dry_run, true)

    # Simple check size
    query =
      from s in schema_mod,
        where: not is_nil(field(s, ^encrypted_field)),
        order_by: [asc: :id]

    # Use chunking stream
    Repo.transaction(
      fn ->
        query
        |> Repo.stream()
        |> Enum.reduce(%{success: 0, failed: 0, skipped: 0}, fn record, counts ->
          process_record(record, schema_mod, encrypted_field, dry_run?, counts)
        end)
      end,
      timeout: :infinity
    )
    |> case do
      {:ok, results} -> results
      {:error, reason} -> {:error, reason}
    end
  end

  defp process_record(record, schema_mod, encrypted_field, dry_run?, counts) do
    payload = Map.get(record, encrypted_field)

    cond do
      !is_map(payload) ->
        Map.update!(counts, :skipped, &(&1 + 1))

      not Map.has_key?(payload, "wrapped_dek") and not Map.has_key?(payload, :wrapped_dek) ->
        Map.update!(counts, :skipped, &(&1 + 1))

      true ->
        wrapped_dek = Map.get(payload, "wrapped_dek") || Map.get(payload, :wrapped_dek)

        # Determine billing_id
        billing_id =
          if Map.has_key?(record, :billing_account_id),
            do: Map.get(record, :billing_account_id),
            else: nil

        field_ref = %{
          billing_account_id: billing_id,
          table: schema_mod.__schema__(:source),
          field: to_string(encrypted_field),
          row_id: record.id
        }

        if dry_run? do
          Map.update!(counts, :success, &(&1 + 1))
        else
          do_rewrap(record, field_ref, wrapped_dek, payload, encrypted_field, counts)
        end
    end
  end

  defp do_rewrap(record, field_ref, wrapped_dek, payload, encrypted_field, counts) do
    case VaultTransitProvider.rewrap(field_ref, wrapped_dek) do
      {:ok, %{wrapped_dek: new_wrapped, key_version: new_version}} ->
        if new_wrapped != wrapped_dek do
          new_payload =
            payload
            |> stringify_keys()
            |> Map.put("wrapped_dek", new_wrapped)
            |> Map.put("key_version", new_version)

          record
          |> Ecto.Changeset.change(%{encrypted_field => new_payload})
          |> Repo.update()
          |> case do
            {:ok, _} -> Map.update!(counts, :success, &(&1 + 1))
            _ -> Map.update!(counts, :failed, &(&1 + 1))
          end
        else
          # Already on latest key (Transit returned the same wrapped_dek / or equivalent state)
          Map.update!(counts, :skipped, &(&1 + 1))
        end

      _err ->
        Map.update!(counts, :failed, &(&1 + 1))
    end
  end

  defp stringify_keys(map) do
    Map.new(map, fn {k, v} -> {to_string(k), v} end)
  end
end
