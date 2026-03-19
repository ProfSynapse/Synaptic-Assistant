defmodule Assistant.ExecutionLogs.Content do
  @moduledoc """
  Handles encryption and hydration for ExecutionLogs fields manually.
  """
  alias Assistant.Encryption
  alias Assistant.Repo
  alias Assistant.Schemas.{ExecutionLog, Conversation}

  @doc """
  Prepares attributes for insertion/update by securely dual-writing
  `parameters` and `result` if we have a valid context.
  """
  def prepare_log_attrs(attrs, conversation_id) do
    case Repo.get(Conversation, conversation_id) do
      nil -> attrs
      conversation ->
        billing_id = conversation.billing_account_id
        attrs = Map.put(attrs, :billing_account_id, billing_id)

        attrs
        |> maybe_encrypt_field(:parameters, billing_id)
        |> maybe_encrypt_field(:result, billing_id)
        |> maybe_encrypt_field(:error_message, billing_id)
    end
  end

  defp maybe_encrypt_field(attrs, field, billing_id) do
    case Map.get(attrs, field) do
      nil -> attrs
      val ->
        # ensure map to string for json, except error_message which is string
        plaintext =
          if is_map(val), do: struct_to_json(val), else: to_string(val)
        
        # Don't encrypt empty maps or empty strings
        if plaintext == "{}" or plaintext == "" do
          attrs
        else
          context = %{
            billing_account_id: billing_id,
            table: "execution_logs",
            field: "#{field}_encrypted",
            row_id: nil
          }
          
          case Encryption.encrypt(context, plaintext) do
            {:ok, ciphertext_payload} ->
              Map.put(attrs, :"#{field}_encrypted", ciphertext_payload)
            _ -> attrs
          end
        end
    end
  end

  defp struct_to_json(map) when is_map(map) do
    # basic conversion to json string, dropping unencodable
    try do
      Jason.encode!(map)
    rescue
      _ -> inspect(map)
    end
  end
  defp struct_to_json(other), do: to_string(other)

  @doc """
  Hydrates fully-loaded execution logs.
  """
  def hydrate_logs(logs) when is_list(logs) do
    Enum.map(logs, &hydrate_log/1)
  end

  def hydrate_log(%ExecutionLog{} = log) do
    log
    |> hydrate_field(:parameters, :parameters_encrypted, true)
    |> hydrate_field(:result, :result_encrypted, true)
    |> hydrate_field(:error_message, :error_message_encrypted, false)
  end
  def hydrate_log(other), do: other

  defp hydrate_field(log, plain_field, enc_field, is_json) do
    enc_val = Map.get(log, enc_field)
    
    if is_map(enc_val) and Map.has_key?(enc_val, "ciphertext") and not is_nil(log.billing_account_id) do
      context = %{
        billing_account_id: log.billing_account_id,
        table: "execution_logs",
        field: to_string(enc_field),
        row_id: log.id
      }
      
      case Encryption.decrypt(context, enc_val) do
        {:ok, plaintext} ->
          final_val = if is_json, do: parse_json(plaintext, Map.get(log, plain_field)), else: plaintext
          Map.put(log, plain_field, final_val)
        _ -> log
      end
    else
      log
    end
  end

  defp parse_json(str, fallback) do
    case Jason.decode(str, keys: :atoms) do
      {:ok, map} -> map
      _ -> fallback
    end
  end
end