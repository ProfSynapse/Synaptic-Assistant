# lib/assistant/workers/auth_token_cleanup_worker.ex — Periodic cleanup of expired auth_tokens.
#
# Runs as an Oban cron job to delete auth_tokens rows that are expired or consumed.
# This prevents unbounded growth of the auth_tokens table from magic link usage.
#
# Related files:
#   - lib/assistant/schemas/auth_token.ex (Ecto schema)
#   - lib/assistant/auth/magic_link.ex (generates/consumes auth_tokens)
#   - config/config.exs (Oban cron configuration)

defmodule Assistant.Workers.AuthTokenCleanupWorker do
  @moduledoc """
  Oban cron worker that deletes stale auth_token rows.

  Targets rows that are either:
  - Consumed (used_at IS NOT NULL) and older than 24 hours
  - Expired (expires_at < now) and older than 24 hours

  Runs daily in the :default queue via Oban cron.
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 1

  require Logger

  import Ecto.Query

  alias Assistant.Repo
  alias Assistant.Schemas.AuthToken

  @retention_hours 24

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    cutoff = DateTime.add(DateTime.utc_now(), -@retention_hours * 3600, :second)

    {deleted, _} =
      from(t in AuthToken,
        where:
          (not is_nil(t.used_at) and t.inserted_at < ^cutoff) or
            (t.expires_at < ^cutoff)
      )
      |> Repo.delete_all()

    if deleted > 0 do
      Logger.info("AuthTokenCleanupWorker: purged stale auth_tokens",
        deleted_count: deleted
      )
    end

    :ok
  end
end
