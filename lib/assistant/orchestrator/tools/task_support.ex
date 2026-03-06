# Shared helpers for orchestrator-native task tools.

defmodule Assistant.Orchestrator.Tools.TaskSupport do
  @moduledoc false

  alias Assistant.TaskManager.Queries

  @spec ensure_user_id(map()) :: {:ok, String.t()} | {:error, String.t()}
  def ensure_user_id(loop_state) do
    case loop_state[:user_id] do
      user_id when is_binary(user_id) and user_id != "" ->
        {:ok, user_id}

      _ ->
        {:error, "Task tools require a user context."}
    end
  end

  @spec conversation_id(map()) :: String.t() | nil
  def conversation_id(loop_state) do
    case loop_state[:conversation_id] do
      conversation_id when is_binary(conversation_id) and conversation_id != "" -> conversation_id
      _ -> nil
    end
  end

  @spec resolve_task(String.t(), map()) ::
          {:ok, Assistant.Schemas.Task.t()} | {:error, String.t()}
  def resolve_task(task_ref, loop_state) when is_binary(task_ref) and task_ref != "" do
    with {:ok, user_id} <- ensure_user_id(loop_state) do
      case Queries.get_task(task_ref, user_id) do
        {:ok, task} -> {:ok, task}
        {:error, :not_found} -> {:error, "Task not found: #{task_ref}"}
      end
    end
  end

  def resolve_task(_task_ref, _loop_state), do: {:error, "Missing required field: task_ref"}

  @spec parse_date(term()) :: Date.t() | nil | :invalid
  def parse_date(nil), do: nil
  def parse_date(""), do: nil

  def parse_date(date_str) when is_binary(date_str) do
    case Date.from_iso8601(date_str) do
      {:ok, date} -> date
      {:error, _} -> :invalid
    end
  end

  def parse_date(_), do: :invalid

  @spec parse_tags(term()) :: [String.t()] | nil
  def parse_tags(nil), do: nil
  def parse_tags([]), do: []

  def parse_tags(tags) when is_list(tags) do
    tags
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  def parse_tags(tags) when is_binary(tags) do
    tags
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  def parse_tags(_), do: nil

  @spec format_changeset_errors(Ecto.Changeset.t()) :: String.t()
  def format_changeset_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
    |> Enum.map_join("; ", fn {field, msgs} -> "#{field}: #{Enum.join(msgs, ", ")}" end)
  end
end
