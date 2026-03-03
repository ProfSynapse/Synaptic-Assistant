# lib/assistant/channels/conversation_archiver.ex — Oban worker for archiving stale conversations.
#
# Runs daily via Oban Cron to mark conversations as "archived" when they have
# been inactive longer than the configured threshold. Only "active" and "idle"
# conversations are eligible; "closed" conversations are left untouched.
#
# Related files:
#   - lib/assistant/schemas/conversation.ex (Conversation schema with status field)
#   - config/config.exs (Oban cron + maintenance queue configuration)

defmodule Assistant.Channels.ConversationArchiver do
  @moduledoc """
  Oban worker that archives stale conversations.

  Runs on a daily schedule and transitions conversations from "active" or "idle"
  to "archived" when their `last_active_at` timestamp exceeds the configured
  threshold (default: 30 days).

  ## Configuration

    * `:conversation_archive_days` — Number of days of inactivity before
      archival (default: 30). Set via `Application.get_env(:assistant, ...)`.

  ## Behavior

    * Only conversations with status "active" or "idle" are eligible
    * Conversations with status "closed" are never archived
    * Uses a bulk update for efficiency (no per-row changeset validation)
    * Returns `{:ok, count}` with the number of archived conversations
  """

  use Oban.Worker, queue: :maintenance, max_attempts: 3

  import Ecto.Query

  alias Assistant.Repo

  require Logger

  @default_archive_days 30
  @archivable_statuses ["active", "idle"]

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    archive_days =
      Application.get_env(:assistant, :conversation_archive_days, @default_archive_days)

    cutoff = DateTime.add(DateTime.utc_now(), -archive_days, :day)

    {count, _} =
      from(c in "conversations",
        where: c.status in @archivable_statuses,
        where: c.last_active_at < ^cutoff
      )
      |> Repo.update_all(set: [status: "archived", updated_at: DateTime.utc_now()])

    Logger.info("Conversation archival complete",
      archived_count: count,
      cutoff_date: DateTime.to_iso8601(cutoff),
      archive_days: archive_days
    )

    {:ok, count}
  end
end
