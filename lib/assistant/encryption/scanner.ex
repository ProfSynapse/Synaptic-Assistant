defmodule Assistant.Encryption.Scanner do
  @moduledoc """
  Operator tooling for batch integrity checking and repair of encrypted fields.
  """
  import Ecto.Query
  alias Assistant.Repo
  alias Assistant.Encryption

  require Logger

  @doc """
  Runs an integrity check over a specific schema and field. Returns a summary of valid vs failed rows.
  If a `plaintext_field` is provided and `repair: true`, it will attempt to re-encrypt rows that failed decryption.
  
  Example:
      Assistant.Encryption.Scanner.scan(Assistant.Schemas.ExecutionLog, :parameters_encrypted, plaintext_field: :parameters, repair: false)
  """
  @default_batch_size 200

  def scan(schema_mod, encrypted_field, opts \\ []) do
    plaintext_field = Keyword.get(opts, :plaintext_field)
    repair? = Keyword.get(opts, :repair, false)
    batch_size = Keyword.get(opts, :batch_size, @default_batch_size)

    initial_acc = %{valid: 0, corrupted: 0, repaired: 0, skipped: 0, failures: []}

    do_batched_scan(schema_mod, encrypted_field, plaintext_field, repair?, batch_size, initial_acc, nil)
  end

  defp do_batched_scan(schema_mod, encrypted_field, plaintext_field, repair?, batch_size, acc, last_id) do
    query =
      from s in schema_mod,
        where: not is_nil(field(s, ^encrypted_field)),
        order_by: [asc: :id],
        limit: ^batch_size

    query = if last_id, do: where(query, [s], s.id > ^last_id), else: query

    rows = Repo.all(query)

    case rows do
      [] ->
        acc

      rows ->
        new_acc =
          Enum.reduce(rows, acc, fn record, inner_acc ->
            process_record(record, schema_mod, encrypted_field, plaintext_field, repair?, inner_acc)
          end)

        new_last_id = List.last(rows).id
        Logger.info("Scanner: processed batch of #{length(rows)}, last_id=#{new_last_id}")

        do_batched_scan(schema_mod, encrypted_field, plaintext_field, repair?, batch_size, new_acc, new_last_id)
    end
  end

  defp process_record(record, schema_mod, encrypted_field, plaintext_field, repair?, acc) do
    payload = Map.get(record, encrypted_field)
    
    if is_map(payload) and (Map.has_key?(payload, "ciphertext") or Map.has_key?(payload, :ciphertext)) do
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
      
      # Attempt Decrypt
      case Encryption.decrypt(field_ref, stringify_keys(payload)) do
        {:ok, decrypted_binary} ->
          # Check against plaintext if provided
          if plaintext_field && not is_nil(Map.get(record, plaintext_field)) do
            # We assume JSON encoding for maps/lists, binary for others.
            pt = Map.get(record, plaintext_field)
            expected_binary = if is_binary(pt), do: pt, else: Jason.encode!(pt)
            
            if decrypted_binary == expected_binary do
              Map.update!(acc, :valid, &(&1 + 1))
            else
              handle_corrupted(record, field_ref, expected_binary, encrypted_field, plaintext_field, repair?, acc)
            end
          else
            Map.update!(acc, :valid, &(&1 + 1))
          end

        {:error, reason} ->
          pt = if plaintext_field, do: Map.get(record, plaintext_field), else: nil
          if pt do
            expected_binary = if is_binary(pt), do: pt, else: Jason.encode!(pt)
            handle_corrupted(record, field_ref, expected_binary, encrypted_field, plaintext_field, repair?, %{acc | failures: [{record.id, reason} | acc.failures]})
          else
            %{acc | corrupted: acc.corrupted + 1, failures: [{record.id, reason} | acc.failures]}
          end
      end
    else
      Map.update!(acc, :skipped, &(&1 + 1))
    end
  end

  defp handle_corrupted(record, field_ref, plaintext_binary, encrypted_field, _plaintext_field, repair?, acc) do
    table = field_ref.table

    if repair? do
      case Encryption.encrypt(field_ref, plaintext_binary) do
        {:ok, new_encrypted_payload} ->
          record
          |> Ecto.Changeset.change(%{encrypted_field => new_encrypted_payload})
          |> Repo.update()
          |> case do
            {:ok, _} ->
              Map.update!(acc, :repaired, &(&1 + 1))

            {:error, changeset} ->
              Logger.warning("Scanner: failed to save repaired ciphertext for #{table} id=#{record.id}",
                error: inspect(changeset.errors)
              )

              Map.update!(acc, :corrupted, &(&1 + 1))
          end

        {:error, reason} ->
          Logger.warning("Scanner: failed to re-encrypt for repair on #{table} id=#{record.id}",
            error: inspect(reason)
          )

          Map.update!(acc, :corrupted, &(&1 + 1))
      end
    else
      Map.update!(acc, :corrupted, &(&1 + 1))
    end
  end

  defp stringify_keys(map) do
    Map.new(map, fn {k, v} -> {to_string(k), v} end)
  end
end
