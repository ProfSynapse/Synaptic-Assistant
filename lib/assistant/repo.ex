# lib/assistant/repo.ex — Ecto repository for PostgreSQL.
#
# All database queries go through this module. Uses binary_id (UUIDs)
# as the default primary key type for all schemas.
#
# Configures pgvector search parameters on each new connection via
# after_connect callback (see configure_vector_search migration).

defmodule Assistant.Repo do
  use Ecto.Repo,
    otp_app: :assistant,
    adapter: Ecto.Adapters.Postgres

  @doc false
  def init(_type, config) do
    config =
      Keyword.put_new(config, :after_connect, fn conn ->
        # Configure pgvector session parameters (ef_search, iterative_scan)
        # for multi-tenant filtered vector search. The function is created by
        # migration 20260319120003. Silently ignored if the function doesn't
        # exist yet (e.g., during initial migration run on a fresh database).
        try do
          Postgrex.query(conn, "SELECT configure_vector_search()", [])
        rescue
          _ -> :ok
        end
      end)

    {:ok, config}
  end
end

Postgrex.Types.define(
  Assistant.PostgrexTypes,
  [Pgvector.Extensions.Vector] ++ Ecto.Adapters.Postgres.extensions(),
  []
)
