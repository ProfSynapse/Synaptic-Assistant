defmodule Assistant.TaskManager.Content do
  @moduledoc false

  import Ecto.Query

  alias Assistant.Encryption
  alias Assistant.Repo
  alias Assistant.Schemas.User
  alias Assistant.Schemas.Task

  @spec prepare_task_attrs(binary() | nil, map()) :: {:ok, map()} | {:error, term()}
  def prepare_task_attrs(user_id, attrs)
      when (is_binary(user_id) or is_nil(user_id)) and is_map(attrs) do
    if hosted_mode?() and not is_nil(user_id) do
      case get_attr(attrs, :description) do
        description when is_binary(description) ->
          entry_id = get_attr(attrs, :id) || Ecto.UUID.generate()
          attrs = put_attr(attrs, :id, entry_id)

          with {:ok, billing_account_id} <- billing_account_id_for_user(user_id),
               {:ok, encrypted_payload} <-
                 Encryption.encrypt(field_ref(billing_account_id, entry_id, :tasks, :description), description) do
            {:ok, put_attr(attrs, :description_encrypted, encrypted_payload)}
          end

        _ ->
          {:ok, attrs}
      end
    else
      {:ok, attrs}
    end
  end

  @spec prepare_comment_attrs(binary() | nil, map()) :: {:ok, map()} | {:error, term()}
  def prepare_comment_attrs(user_id, attrs)
      when (is_binary(user_id) or is_nil(user_id)) and is_map(attrs) do
    if hosted_mode?() and not is_nil(user_id) do
      case get_attr(attrs, :content) do
        content when is_binary(content) ->
          entry_id = get_attr(attrs, :id) || Ecto.UUID.generate()
          attrs = put_attr(attrs, :id, entry_id)

          with {:ok, billing_account_id} <- billing_account_id_for_user(user_id),
               {:ok, encrypted_payload} <-
                 Encryption.encrypt(field_ref(billing_account_id, entry_id, :task_comments, :content), content) do
            {:ok, put_attr(attrs, :content_encrypted, encrypted_payload)}
          end

        _ ->
          {:ok, attrs}
      end
    else
      {:ok, attrs}
    end
  end

  @spec hydrate_tasks(struct() | [struct()]) :: {:ok, struct() | [struct()]} | {:error, term()}
  def hydrate_tasks([]), do: {:ok, []}

  def hydrate_tasks(entries) when is_list(entries) do
    if hosted_mode?() do
      entries_by_user = Enum.group_by(entries, & &1.creator_id)

      result =
        Enum.reduce_while(entries_by_user, {:ok, []}, fn {user_id, user_entries}, {:ok, acc} ->
          if user_id do
            with {:ok, billing_account_id} <- billing_account_id_for_user(user_id),
                 {:ok, hydrated_user_entries} <-
                   hydrate_entries_for_billing_account(
                     billing_account_id,
                     user_entries,
                     :description,
                     :description_encrypted,
                     :tasks
                   ) do
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
          hydrated_map = result |> elem(1) |> Map.new(&{&1.id, &1})
          {:ok, Enum.map(entries, &Map.get(hydrated_map, &1.id))}
        {:error, reason} ->
          {:error, reason}
      end
    else
      {:ok, entries}
    end
  end

  def hydrate_tasks(%{__struct__: _} = entry) do
    case hydrate_tasks([entry]) do
      {:ok, [hydrated]} -> {:ok, hydrated}
      {:error, reason} -> {:error, reason}
    end
  end

  def hydrate_tasks!(entries) do
    case hydrate_tasks(entries) do
      {:ok, hydrated} -> hydrated
      {:error, reason} -> raise "failed to hydrate task: #{inspect(reason)}"
    end
  end

  @spec hydrate_comments(struct() | [struct()]) :: {:ok, struct() | [struct()]} | {:error, term()}
  def hydrate_comments([]), do: {:ok, []}

  def hydrate_comments(entries) when is_list(entries) do
    if hosted_mode?() do
      entries_with_user_id = Enum.map(entries, fn entry ->
        if is_nil(entry.author_id) do
          user_id = user_id_from_task(entry.task_id)
          {user_id, entry}
        else
          {entry.author_id, entry}
        end
      end)

      entries_by_user = Enum.group_by(entries_with_user_id, &elem(&1, 0), &elem(&1, 1))

      result =
        Enum.reduce_while(entries_by_user, {:ok, []}, fn {user_id, user_entries}, {:ok, acc} ->
          if user_id do
            with {:ok, billing_account_id} <- billing_account_id_for_user(user_id),
                 {:ok, hydrated_user_entries} <-
                   hydrate_entries_for_billing_account(
                     billing_account_id,
                     user_entries,
                     :content,
                     :content_encrypted,
                     :task_comments
                   ) do
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
          hydrated_map = result |> elem(1) |> Map.new(&{&1.id, &1})
          {:ok, Enum.map(entries, &Map.get(hydrated_map, &1.id))}

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:ok, entries}
    end
  end

  def hydrate_comments(%{__struct__: _} = entry) do
    case hydrate_comments([entry]) do
      {:ok, [hydrated]} -> {:ok, hydrated}
      {:error, reason} -> {:error, reason}
    end
  end

  def hydrate_comments!(entries) do
    case hydrate_comments(entries) do
      {:ok, hydrated} -> hydrated
      {:error, reason} -> raise "failed to hydrate comments: #{inspect(reason)}"
    end
  end

  defp hosted_mode?, do: Encryption.hosted_mode?()

  defp hydrate_entries_for_billing_account(
         billing_account_id,
         entries,
         plaintext_field,
         encrypted_field,
         table_name
       )
       when is_list(entries) do
    entries
    |> Enum.reduce_while({:ok, []}, fn entry, {:ok, hydrated} ->
      case hydrate_entry(billing_account_id, entry, plaintext_field, encrypted_field, table_name) do
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
         %{id: entry_id} = entry,
         plaintext_field,
         encrypted_field,
         table_name
       ) do
    payload = Map.get(entry, encrypted_field)

    case decrypt_field(billing_account_id, entry_id, table_name, plaintext_field, payload) do
      {:ok, plaintext} ->
        entry = 
          if plaintext do
            Map.put(entry, plaintext_field, plaintext)
          else
            entry
          end

        entry =
          if Map.has_key?(entry, :comments) and is_list(entry.comments) do
            case hydrate_comments(entry.comments) do
              {:ok, hydrated_comments} -> Map.put(entry, :comments, hydrated_comments)
              {:error, _reason} -> entry
            end
          else
            entry
          end

        entry =
          if Map.has_key?(entry, :subtasks) and is_list(entry.subtasks) do
            case hydrate_tasks(entry.subtasks) do
              {:ok, hydrated_subtasks} -> Map.put(entry, :subtasks, hydrated_subtasks)
              {:error, _reason} -> entry
            end
          else
            entry
          end

        {:ok, entry}
      {:error, reason} ->
        {:error, {:decrypt_failed, entry_id, reason}}
    end
  end

  defp decrypt_field(_billing_account_id, _entry_id, _table_name, _plaintext_field, nil), do: {:ok, nil}
  defp decrypt_field(_billing_account_id, _entry_id, _table_name, _plaintext_field, payload) when not is_map(payload), do: {:ok, nil}
  defp decrypt_field(billing_account_id, entry_id, table_name, plaintext_field, payload) do
    Encryption.decrypt(field_ref(billing_account_id, entry_id, table_name, plaintext_field), payload)
  end

  def billing_account_id_for_user(user_id) do
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

  defp user_id_from_task(task_id) when is_binary(task_id) do
    from(t in Task, where: t.id == ^task_id, select: t.creator_id)
    |> Repo.one()
  end
  defp user_id_from_task(_), do: nil

  defp field_ref(billing_account_id, row_id, table, field) do
    %{
      billing_account_id: billing_account_id,
      table: table,
      field: field,
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
