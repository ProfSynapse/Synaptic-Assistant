defmodule Assistant.Messages.Content do
  @moduledoc false

  import Ecto.Query

  alias Assistant.Encryption
  alias Assistant.Repo
  alias Assistant.Schemas.Conversation

  @table :messages
  @field :content

  @spec prepare_attrs(binary(), map()) :: {:ok, map()} | {:error, term()}
  def prepare_attrs(conversation_id, attrs) when is_binary(conversation_id) and is_map(attrs) do
    message_id = get_attr(attrs, :id) || Ecto.UUID.generate()
    attrs = put_attr(attrs, :id, message_id)

    if hosted_vault_transit_mode?() do
      case get_attr(attrs, :content) do
        content when is_binary(content) ->
          with {:ok, billing_account_id} <- billing_account_id_for_conversation(conversation_id),
               {:ok, encrypted_payload} <-
                 Encryption.encrypt(field_ref(billing_account_id, message_id), content) do
            {:ok,
             attrs
             |> put_attr(:content, nil)
             |> put_attr(:content_encrypted, encrypted_payload)}
          end

        _ ->
          {:ok, attrs}
      end
    else
      {:ok, attrs}
    end
  end

  @spec hydrate_for_conversation(binary(), [struct()]) :: {:ok, [struct()]} | {:error, term()}
  def hydrate_for_conversation(_conversation_id, messages) when messages == [], do: {:ok, []}

  def hydrate_for_conversation(conversation_id, messages)
      when is_binary(conversation_id) and is_list(messages) do
    if hosted_vault_transit_mode?() do
      with {:ok, billing_account_id} <- billing_account_id_for_conversation(conversation_id) do
        hydrate_for_billing_account(billing_account_id, messages)
      end
    else
      {:ok, messages}
    end
  end

  @spec hydrate_for_conversation!(binary(), [struct()]) :: [struct()]
  def hydrate_for_conversation!(conversation_id, messages) do
    case hydrate_for_conversation(conversation_id, messages) do
      {:ok, hydrated_messages} ->
        hydrated_messages

      {:error, reason} ->
        raise "failed to hydrate message content for conversation #{conversation_id}: #{inspect(reason)}"
    end
  end

  @spec hosted_vault_transit_mode?() :: boolean()
  def hosted_vault_transit_mode?, do: Encryption.mode() == :vault_transit

  defp hydrate_for_billing_account(_billing_account_id, []), do: {:ok, []}

  defp hydrate_for_billing_account(billing_account_id, messages) when is_list(messages) do
    messages
    |> Enum.reduce_while({:ok, []}, fn message, {:ok, hydrated} ->
      case hydrate_message(billing_account_id, message) do
        {:ok, hydrated_message} -> {:cont, {:ok, [hydrated_message | hydrated]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, hydrated} -> {:ok, Enum.reverse(hydrated)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp hydrate_message(_billing_account_id, %{content: content} = message)
       when is_binary(content) do
    {:ok, message}
  end

  defp hydrate_message(
         billing_account_id,
         %{id: message_id, content_encrypted: payload} = message
       )
       when is_map(payload) do
    with {:ok, plaintext} <-
           Encryption.decrypt(field_ref(billing_account_id, message_id), payload) do
      {:ok, %{message | content: plaintext}}
    else
      {:error, reason} ->
        {:error, {:decrypt_failed, message_id, reason}}
    end
  end

  defp hydrate_message(_billing_account_id, message), do: {:ok, message}

  defp billing_account_id_for_conversation(conversation_id) do
    conversation_id
    |> billing_account_query()
    |> Repo.one()
    |> case do
      billing_account_id when is_binary(billing_account_id) and billing_account_id != "" ->
        {:ok, billing_account_id}

      nil ->
        {:error, :missing_billing_account_id}
    end
  end

  defp billing_account_query(conversation_id) do
    from c in Conversation,
      join: u in assoc(c, :user),
      where: c.id == ^conversation_id,
      select: u.billing_account_id
  end

  defp field_ref(billing_account_id, row_id) do
    %{
      billing_account_id: billing_account_id,
      table: @table,
      field: @field,
      row_id: row_id
    }
  end

  defp get_attr(attrs, key) when is_atom(key) do
    Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key))
  end

  defp put_attr(attrs, key, value) when is_atom(key) do
    attrs
    |> Map.put(key, value)
    |> Map.delete(Atom.to_string(key))
  end
end
