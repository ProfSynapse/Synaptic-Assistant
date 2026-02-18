defmodule Assistant.Repo.Migrations.AddLastCompactedMessageIdToConversations do
  @moduledoc """
  Adds boundary tracking for incremental compaction.

  Without this column the compaction algorithm has no reliable way to know
  which messages have already been summarized, causing it to re-summarize
  messages that were already folded into the summary. The column stores the
  ID of the last message included in the most recent compaction batch.

  New column:
    - last_compacted_message_id: FK to messages(id), nullable, SET NULL on delete
  """
  use Ecto.Migration

  def change do
    alter table(:conversations) do
      add :last_compacted_message_id,
          references(:messages, type: :binary_id, on_delete: :nilify_all)
    end
  end
end
