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
  @default_batch_size 200

  def rewrap_schema(schema_mod, encrypted_field, opts \\ []) do
    dry_run? = Keyword.get(opts, :dry_run, true)
    batch_size = Keyword.get(opts, :batch_size, @default_batch_size)
    billing_account_id = Keyword.get(opts, :billing_account_id)

    do_batched_rewrap(schema_mod, encrypted_field, dry_run?, batch_size, billing_account_id, %{success: 0, failed: 0, skipped: 0}, nil)
  end

  defp do_batched_rewrap(schema_mod, encrypted_field, dry_run?, batch_size, billing_account_id, acc, last_id) do
    query =
      from s in schema_mod,
        where: not is_nil(field(s, ^encrypted_field)),
        order_by: [asc: :id],
        limit: ^batch_size

    query = if last_id, do: where(query, [s], s.id > ^last_id), else: query
    query = if billing_account_id, do: where(query, [s], s.billing_account_id == ^billing_account_id), else: query

    rows = Repo.all(query)

    case rows do
      [] ->
        acc

      rows ->
        new_acc =
          Enum.reduce(rows, acc, fn record, counts ->
            process_record(record, schema_mod, encrypted_field, dry_run?, counts)
          end)

        new_last_id = List.last(rows).id
        tenant_tag = if billing_account_id, do: " tenant=#{billing_account_id}", else: ""
        Logger.info("Rewrapper: processed batch of #{length(rows)}, last_id=#{new_last_id}#{tenant_tag}")

        do_batched_rewrap(schema_mod, encrypted_field, dry_run?, batch_size, billing_account_id, new_acc, new_last_id)
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
    table = field_ref.table

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
            {:ok, _} ->
              Map.update!(counts, :success, &(&1 + 1))

            {:error, changeset} ->
              Logger.warning("Rewrapper: failed to save rewrapped DEK for #{table} id=#{record.id}",
                error: inspect(changeset.errors)
              )

              Map.update!(counts, :failed, &(&1 + 1))
          end
        else
          # Already on latest key (Transit returned the same wrapped_dek / or equivalent state)
          Map.update!(counts, :skipped, &(&1 + 1))
        end

      {:error, reason} ->
        Logger.warning("Rewrapper: Vault Transit rewrap failed for #{table} id=#{record.id}",
          error: inspect(reason)
        )

        Map.update!(counts, :failed, &(&1 + 1))
    end
  end

  defp stringify_keys(map) do
    Map.new(map, fn {k, v} -> {to_string(k), v} end)
  end
end
