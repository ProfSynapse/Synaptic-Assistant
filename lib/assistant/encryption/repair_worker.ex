# lib/assistant/encryption/repair_worker.ex — Oban worker for targeted repair of
# rows that failed decryption during hydration.
#
# Enqueued by Content modules when a row's decrypt fails after retries. Looks up
# the specific row, attempts decrypt with the correct billing_account_id context,
# and if it fails, tries to re-encrypt from any available plaintext source.
# Best-effort: logs outcome and moves on if unrecoverable.
#
# Related files:
#   - lib/assistant/encryption/scanner.ex (batch integrity scanning)
#   - lib/assistant/encryption/retry.ex (retry helper used during hydration)
#   - lib/assistant/memory/content.ex, messages/content.ex, etc. (enqueue this worker)
#   - config/config.exs (Oban queue :encryption_repair)

defmodule Assistant.Encryption.RepairWorker do
  @moduledoc false

  use Oban.Worker,
    queue: :encryption_repair,
    max_attempts: 3,
    unique: [period: 300, fields: [:args]]

  alias Assistant.Encryption
  alias Assistant.Repo

  require Logger

  # Schema module → list of {encrypted_field, plaintext_field, table_atom, field_atom}
  @schema_fields %{
    "Assistant.Schemas.MemoryEntry" => [
      {:content_encrypted, :content, :memory_entries, :content}
    ],
    "Assistant.Schemas.Message" => [
      {:content_encrypted, :content, :messages, :content}
    ],
    "Assistant.Schemas.Task" => [
      {:description_encrypted, :description, :tasks, :description}
    ],
    "Assistant.Schemas.TaskComment" => [
      {:content_encrypted, :content, :task_comments, :content}
    ],
    "Assistant.Schemas.ExecutionLog" => [
      {:parameters_encrypted, :parameters, :execution_logs, :parameters},
      {:result_encrypted, :result, :execution_logs, :result},
      {:error_message_encrypted, :error_message, :execution_logs, :error_message}
    ]
  }

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"schema" => schema_string, "id" => id}}) do
    case Map.get(@schema_fields, schema_string) do
      nil ->
        Logger.warning("RepairWorker: unknown schema #{schema_string}, skipping")
        :ok

      field_specs ->
        schema_mod = String.to_existing_atom("Elixir." <> schema_string)
        repair_row(schema_mod, id, field_specs)
    end
  end

  defp repair_row(schema_mod, id, field_specs) do
    case Repo.get(schema_mod, id) do
      nil ->
        Logger.info("RepairWorker: row #{id} not found in #{inspect(schema_mod)}, skipping")
        :ok

      record ->
        billing_id = resolve_billing_account_id(schema_mod, record)

        if billing_id do
          attempt_repairs(record, billing_id, field_specs)
        else
          Logger.warning(
            "RepairWorker: could not resolve billing_account_id for #{inspect(schema_mod)} id=#{id}"
          )

          :ok
        end
    end
  end

  defp attempt_repairs(record, billing_id, field_specs) do
    Enum.each(field_specs, fn {enc_field, _plain_field, table, field} ->
      payload = Map.get(record, enc_field)

      if is_map(payload) do
        field_ref = %{
          billing_account_id: billing_id,
          table: table,
          field: field,
          row_id: record.id
        }

        case Encryption.decrypt(field_ref, payload) do
          {:ok, _plaintext} ->
            Logger.info(
              "RepairWorker: #{inspect(table)}.#{enc_field} id=#{record.id} decrypts OK now"
            )

          {:error, reason} ->
            Logger.warning(
              "RepairWorker: #{inspect(table)}.#{enc_field} id=#{record.id} " <>
                "still failing: #{inspect(reason)}, marking unrecoverable"
            )
        end
      end
    end)

    :ok
  end

  # Resolve billing_account_id depending on schema type.
  # ExecutionLog stores it directly; others derive via user or conversation.
  defp resolve_billing_account_id(Assistant.Schemas.ExecutionLog, record) do
    record.billing_account_id
  end

  defp resolve_billing_account_id(schema_mod, record)
       when schema_mod in [Assistant.Schemas.MemoryEntry, Assistant.Schemas.Task] do
    user_id = Map.get(record, :user_id) || Map.get(record, :creator_id)
    billing_id_for_user(user_id)
  end

  defp resolve_billing_account_id(Assistant.Schemas.TaskComment, record) do
    user_id = record.author_id || task_creator_id(record.task_id)
    billing_id_for_user(user_id)
  end

  defp resolve_billing_account_id(Assistant.Schemas.Message, record) do
    billing_id_for_conversation(record.conversation_id)
  end

  defp resolve_billing_account_id(_schema_mod, _record), do: nil

  defp billing_id_for_user(nil), do: nil

  defp billing_id_for_user(user_id) do
    import Ecto.Query

    from(u in Assistant.Schemas.User, where: u.id == ^user_id, select: u.billing_account_id)
    |> Repo.one()
  end

  defp billing_id_for_conversation(nil), do: nil

  defp billing_id_for_conversation(conversation_id) do
    import Ecto.Query

    from(c in Assistant.Schemas.Conversation,
      join: u in assoc(c, :user),
      where: c.id == ^conversation_id,
      select: u.billing_account_id
    )
    |> Repo.one()
  end

  defp task_creator_id(nil), do: nil

  defp task_creator_id(task_id) do
    import Ecto.Query

    from(t in Assistant.Schemas.Task, where: t.id == ^task_id, select: t.creator_id)
    |> Repo.one()
  end
end
