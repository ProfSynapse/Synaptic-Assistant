defmodule Assistant.ExecutionLogs.Content do
  @moduledoc """
  Handles encryption and hydration for ExecutionLog fields.
  Derives billing_account_id via conversation → user → user.billing_account_id,
  consistent with the other Content modules.
  """

  import Ecto.Query

  require Logger

  alias Assistant.Encryption
  alias Assistant.Encryption.{RepairWorker, Retry}
  alias Assistant.Repo
  alias Assistant.Schemas.{ExecutionLog, Conversation, User}

  @doc """
  Prepares attributes for insertion/update by encrypting
  `parameters`, `result`, and `error_message` if billing context is available.
  """
  def prepare_log_attrs(attrs, conversation_id) do
    case billing_account_id_for_conversation(conversation_id) do
      {:ok, billing_id} ->
        attrs
        |> Map.put(:billing_account_id, billing_id)
        |> maybe_encrypt_field(:parameters, billing_id)
        |> maybe_encrypt_field(:result, billing_id)
        |> maybe_encrypt_field(:error_message, billing_id)

      {:error, _reason} ->
        attrs
    end
  end

  defp maybe_encrypt_field(attrs, field, billing_id) do
    case Map.get(attrs, field) do
      nil ->
        attrs

      val ->
        plaintext =
          if is_map(val), do: struct_to_json(val), else: to_string(val)

        if plaintext == "{}" or plaintext == "" do
          attrs
        else
          context = %{
            billing_account_id: billing_id,
            table: :execution_logs,
            field: field,
            row_id: nil
          }

          case Encryption.encrypt(context, plaintext) do
            {:ok, ciphertext_payload} ->
              Map.put(attrs, :"#{field}_encrypted", ciphertext_payload)

            _ ->
              attrs
          end
        end
    end
  end

  defp struct_to_json(map) when is_map(map) do
    try do
      Jason.encode!(map)
    rescue
      _ -> inspect(map)
    end
  end

  defp struct_to_json(other), do: to_string(other)

  @doc """
  Hydrates fully-loaded execution logs by decrypting encrypted fields.
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

    if is_map(enc_val) and Map.has_key?(enc_val, "ciphertext") and
         not is_nil(log.billing_account_id) do
      context = %{
        billing_account_id: log.billing_account_id,
        table: :execution_logs,
        field: plain_field,
        row_id: log.id
      }

      case Retry.with_retry(fn -> Encryption.decrypt(context, enc_val) end) do
        {:ok, plaintext} ->
          final_val =
            if is_json, do: parse_json(plaintext, Map.get(log, plain_field)), else: plaintext

          Map.put(log, plain_field, final_val)

        {:error, reason} ->
          Logger.warning(
            "Decrypt failed for execution_logs id=#{log.id} field=#{plain_field}, enqueueing repair",
            error: inspect(reason)
          )

          enqueue_repair(log.id)
          log
      end
    else
      log
    end
  end

  defp billing_account_id_for_conversation(conversation_id) do
    conversation_id
    |> billing_account_query()
    |> Repo.one()
    |> case do
      billing_account_id when is_binary(billing_account_id) and billing_account_id != "" ->
        {:ok, billing_account_id}

      nil ->
        if Encryption.mode() == :vault_transit do
          {:error, :missing_billing_account_id}
        else
          {:ok, "local"}
        end
    end
  end

  defp billing_account_query(conversation_id) do
    from c in Conversation,
      join: u in User,
      on: u.id == c.user_id,
      where: c.id == ^conversation_id,
      select: u.billing_account_id
  end

  defp enqueue_repair(id) do
    %{"schema" => "Assistant.Schemas.ExecutionLog", "id" => id}
    |> RepairWorker.new()
    |> Oban.insert()
  end

  defp parse_json(str, fallback) do
    case Jason.decode(str, keys: :atoms) do
      {:ok, map} -> map
      _ -> fallback
    end
  end
end