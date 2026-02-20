# lib/assistant/workers/auth_token_cleanup_worker.ex — Oban cron worker for
# purging expired auth_tokens.
#
# Runs daily at 03:00 UTC (configured in config/config.exs Oban cron).
# Deletes auth_token rows that are both expired (expires_at < now) AND
# already used (used_at IS NOT NULL). Pending (unused) tokens are left alone
# even if expired — they are harmless and may be useful for audit.
#
# Related files:
#   - lib/assistant/schemas/auth_token.ex (schema)
#   - lib/assistant/auth/token_store.ex (token CRUD)
#   - config/config.exs (Oban cron schedule)

defmodule Assistant.Workers.AuthTokenCleanupWorker do
  @moduledoc """
  Oban cron worker that purges expired, already-used auth tokens.

  Runs daily at 03:00 UTC. Only deletes rows where `expires_at < NOW()`
  AND `used_at IS NOT NULL` — pending tokens are never deleted, even if
  expired, to preserve the audit trail and avoid races with in-flight
  OAuth callbacks.

  ## Queue

  Runs in the `:default` queue (no dedicated queue needed for a daily
  lightweight cleanup job).
  """

  use Oban.Worker, queue: :default, max_attempts: 3

  import Ecto.Query

  alias Assistant.Repo
  alias Assistant.Schemas.AuthToken

  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    now = DateTime.utc_now()

    {deleted_count, _} =
      AuthToken
      |> where([t], t.expires_at < ^now)
      |> where([t], not is_nil(t.used_at))
      |> Repo.delete_all()

    if deleted_count > 0 do
      Logger.info("AuthTokenCleanupWorker: purged #{deleted_count} expired token(s)")
    end

    :ok
  end
end
