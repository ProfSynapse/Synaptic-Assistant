defmodule Assistant.Memory.ConversationSummary do
  @moduledoc false

  import Ecto.Query

  alias Assistant.Encryption
  alias Assistant.Repo
  alias Assistant.Schemas.Conversation

  @table :conversations
  @field :summary

  @spec maybe_encrypt(binary(), String.t() | nil) :: {:ok, map() | nil} | {:error, term()}
  def maybe_encrypt(_conversation_id, nil), do: {:ok, nil}

  def maybe_encrypt(conversation_id, summary_text) when is_binary(summary_text) do
    if hosted_mode?() do
      with {:ok, billing_account_id} <- billing_account_id_for_conversation(conversation_id),
           {:ok, encrypted_payload} <-
             Encryption.encrypt(field_ref(billing_account_id, conversation_id), summary_text) do
        {:ok, encrypted_payload}
      end
    else
      {:ok, nil}
    end
  end

  @spec hydrate(struct() | [struct()]) :: {:ok, struct() | [struct()]} | {:error, term()}
  def hydrate([]), do: {:ok, []}

  def hydrate(conversations) when is_list(conversations) do
    if hosted_mode?() do
      conversations_by_billing = group_by_billing_account(conversations)

      result =
        Enum.reduce_while(conversations_by_billing, {:ok, []}, fn {billing_account_id, convs},
                                                                  {:ok, acc} ->
          if billing_account_id do
            case hydrate_for_billing_account(billing_account_id, convs) do
              {:ok, hydrated_convs} -> {:cont, {:ok, hydrated_convs ++ acc}}
              {:error, reason} -> {:halt, {:error, reason}}
            end
          else
            {:cont, {:ok, convs ++ acc}}
          end
        end)

      case result do
        {:ok, _} ->
          hydrated_map =
            result
            |> elem(1)
            |> Map.new(&{&1.id, &1})

          {:ok, Enum.map(conversations, &Map.get(hydrated_map, &1.id))}

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:ok, conversations}
    end
  end

  def hydrate(%{__struct__: _} = conv) do
    case hydrate([conv]) do
      {:ok, [hydrated]} -> {:ok, hydrated}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec hydrate!(struct() | [struct()]) :: struct() | [struct()]
  def hydrate!(conversations) do
    case hydrate(conversations) do
      {:ok, hydrated} -> hydrated
      {:error, reason} -> raise "failed to hydrate conversation summary: #{inspect(reason)}"
    end
  end

  defp hosted_mode?, do: Encryption.hosted_mode?()

  defp hydrate_for_billing_account(billing_account_id, conversations)
       when is_list(conversations) do
    conversations
    |> Enum.reduce_while({:ok, []}, fn conv, {:ok, hydrated} ->
      case hydrate_conversation(billing_account_id, conv) do
        {:ok, hydrated_conv} -> {:cont, {:ok, [hydrated_conv | hydrated]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, hydrated} -> {:ok, Enum.reverse(hydrated)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp hydrate_conversation(
         billing_account_id,
         %{id: conv_id, summary_encrypted: payload, summary: summary_text} = conv
       )
       when is_map(payload) do
    # Prefer plaintext if available and not empty
    if is_binary(summary_text) and summary_text != "" do
      {:ok, conv}
    else
      with {:ok, plaintext} <- Encryption.decrypt(field_ref(billing_account_id, conv_id), payload) do
        {:ok, %{conv | summary: plaintext}}
      else
        {:error, reason} ->
          {:error, {:decrypt_failed, conv_id, reason}}
      end
    end
  end

  defp hydrate_conversation(_billing_account_id, conv), do: {:ok, conv}

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

  defp group_by_billing_account(conversations) do
    conv_ids = Enum.map(conversations, & &1.id)

    mapping =
      from(c in Conversation,
        join: u in assoc(c, :user),
        where: c.id in ^conv_ids,
        select: {c.id, u.billing_account_id}
      )
      |> Repo.all()
      |> Map.new()

    Enum.group_by(conversations, fn conv -> Map.get(mapping, conv.id) end)
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
end
