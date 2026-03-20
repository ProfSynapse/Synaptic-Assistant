defmodule Assistant.Memory.Content do
  @moduledoc false

  import Ecto.Query

  require Logger

  alias Assistant.Encryption
  alias Assistant.Encryption.{RepairWorker, Retry}
  alias Assistant.Repo
  alias Assistant.Schemas.User

  @table :memory_entries
  @field :content

  @spec prepare_attrs(binary() | nil, map()) :: {:ok, map()} | {:error, term()}
  def prepare_attrs(user_id, attrs)
      when (is_binary(user_id) or is_nil(user_id)) and is_map(attrs) do
    if not is_nil(user_id) do
      case get_attr(attrs, :content) do
        content when is_binary(content) ->
          entry_id = get_attr(attrs, :id) || Ecto.UUID.generate()
          attrs = put_attr(attrs, :id, entry_id)

          title = get_attr(attrs, :title) || derive_title(content)
          attrs = put_attr(attrs, :title, title)

          with {:ok, billing_account_id} <- billing_account_id_for_user(user_id),
               {:ok, encrypted_payload} <-
                 Encryption.encrypt(field_ref(billing_account_id, entry_id), content) do
            {:ok, attrs |> put_attr(:content_encrypted, encrypted_payload)}
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
    if true do
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


  defp hydrate_for_billing_account(billing_account_id, entries) when is_list(entries) do
    hydrated =
      Enum.map(entries, fn entry ->
        case hydrate_entry(billing_account_id, entry) do
          {:ok, hydrated_entry} ->
            hydrated_entry

          {:error, {:decrypt_failed, entry_id, reason}} ->
            Logger.warning(
              "Decrypt failed for memory_entries id=#{entry_id} field=content, enqueueing repair",
              error: inspect(reason)
            )

            enqueue_repair("Assistant.Schemas.MemoryEntry", entry_id)
            %{entry | content: nil}
        end
      end)

    {:ok, hydrated}
  end

  defp hydrate_entry(
         billing_account_id,
         %{id: entry_id, content_encrypted: payload, content: _content} = entry
       )
       when is_map(payload) do
    case Retry.with_retry(fn ->
           Encryption.decrypt(field_ref(billing_account_id, entry_id), payload)
         end) do
      {:ok, plaintext} ->
        {:ok, %{entry | content: plaintext}}

      {:error, reason} ->
        {:error, {:decrypt_failed, entry_id, reason}}
    end
  end

  defp hydrate_entry(_billing_account_id, entry), do: {:ok, entry}

  def billing_account_id_for_user(nil), do: {:error, :missing_billing_account_id}
  def billing_account_id_for_user(user_id) do
    user_id
    |> billing_account_query()
    |> Repo.one()
    |> case do
      billing_account_id when is_binary(billing_account_id) and billing_account_id != "" ->
        {:ok, billing_account_id}

      nil ->
        if Encryption.mode() == :vault_transit do
          {:error, :missing_billing_account_id}
        else
          # Consistent fallback for self-hosted / local dev without billing accounts
          {:ok, "local"}
        end
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

  defp enqueue_repair(schema, id) do
    %{"schema" => schema, "id" => id}
    |> RepairWorker.new()
    |> Oban.insert()
  end

  defp derive_title(content) do
    content
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> String.slice(0, 160)
    |> case do
      "" -> "Untitled memory"
      title -> title
    end
  end
end
