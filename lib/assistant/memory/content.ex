defmodule Assistant.Memory.Content do
  @moduledoc false

  import Ecto.Query

  alias Assistant.Encryption
  alias Assistant.Repo
  alias Assistant.Schemas.User

  @table :memory_entries
  @field :content

  @spec prepare_attrs(binary() | nil, map()) :: {:ok, map()} | {:error, term()}
  def prepare_attrs(user_id, attrs)
      when (is_binary(user_id) or is_nil(user_id)) and is_map(attrs) do
    if hosted_mode?() and not is_nil(user_id) do
      case get_attr(attrs, :content) do
        content when is_binary(content) ->
          entry_id = get_attr(attrs, :id) || Ecto.UUID.generate()
          attrs = put_attr(attrs, :id, entry_id)

          with {:ok, billing_account_id} <- billing_account_id_for_user(user_id),
               {:ok, encrypted_payload} <-
                 Encryption.encrypt(field_ref(billing_account_id, entry_id), content) do
            # Dual-writing plaintext, just like messages should theoretically do when dual writing is enabled
            {:ok, put_attr(attrs, :content_encrypted, encrypted_payload)}
          end

        _ ->
          {:ok, attrs}
      end
    else
      {:ok, attrs}
    end
  end

  @spec hydrate(struct() | [struct()]) :: {:ok, struct() | [struct()]} | {:error, term()}
  def hydrate([]), do: {:ok, []}

  def hydrate(entries) when is_list(entries) do
    if hosted_mode?() do
      # Group by user_id to minimize user queries
      entries_by_user = Enum.group_by(entries, & &1.user_id)

      result =
        Enum.reduce_while(entries_by_user, {:ok, []}, fn {user_id, user_entries}, {:ok, acc} ->
          if user_id do
            with {:ok, billing_account_id} <- billing_account_id_for_user(user_id),
                 {:ok, hydrated_user_entries} <-
                   hydrate_for_billing_account(billing_account_id, user_entries) do
              {:cont, {:ok, hydrated_user_entries ++ acc}}
            else
              {:error, reason} -> {:halt, {:error, reason}}
            end
          else
            {:cont, {:ok, user_entries ++ acc}}
          end
        end)

      case result do
        {:ok, _} ->
          hydrated_map =
            result
            |> elem(1)
            |> Map.new(&{&1.id, &1})

          {:ok, Enum.map(entries, &Map.get(hydrated_map, &1.id))}

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:ok, entries}
    end
  end

  def hydrate(%{__struct__: _} = entry) do
    case hydrate([entry]) do
      {:ok, [hydrated]} -> {:ok, hydrated}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec hydrate!(struct() | [struct()]) :: struct() | [struct()]
  def hydrate!(entries) do
    case hydrate(entries) do
      {:ok, hydrated} -> hydrated
      {:error, reason} -> raise "failed to hydrate memory content: #{inspect(reason)}"
    end
  end

  defp hosted_mode?, do: Encryption.hosted_mode?()

  defp hydrate_for_billing_account(billing_account_id, entries) when is_list(entries) do
    entries
    |> Enum.reduce_while({:ok, []}, fn entry, {:ok, hydrated} ->
      case hydrate_entry(billing_account_id, entry) do
        {:ok, hydrated_entry} -> {:cont, {:ok, [hydrated_entry | hydrated]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, hydrated} -> {:ok, Enum.reverse(hydrated)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp hydrate_entry(
         billing_account_id,
         %{id: entry_id, content_encrypted: payload, content: _content} = entry
       )
       when is_map(payload) do
    # If content is already a string and not empty, it means we dual-wrote and have plaintext.
    # Note: wait, if it's dual written but not fetched from DB? Ecto fetches whatever is in DB.
    # If the DB has plaintext, we don't *need* to decrypt unless we want to verify.
    # Let's prefer the decrypted value to ensure the feature is fully active.
    with {:ok, plaintext} <- Encryption.decrypt(field_ref(billing_account_id, entry_id), payload) do
      {:ok, %{entry | content: plaintext}}
    else
      {:error, reason} ->
        {:error, {:decrypt_failed, entry_id, reason}}
    end
  end

  defp hydrate_entry(_billing_account_id, entry), do: {:ok, entry}

  defp billing_account_id_for_user(user_id) do
    user_id
    |> billing_account_query()
    |> Repo.one()
    |> case do
      billing_account_id when is_binary(billing_account_id) and billing_account_id != "" ->
        {:ok, billing_account_id}

      nil ->
        {:error, :missing_billing_account_id}
    end
  end

  defp billing_account_query(user_id) do
    from u in User,
      where: u.id == ^user_id,
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
