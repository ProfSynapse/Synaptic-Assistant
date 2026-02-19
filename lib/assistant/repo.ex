# lib/assistant/repo.ex — Ecto repository for PostgreSQL.
#
# All database queries go through this module. Uses binary_id (UUIDs)
# as the default primary key type for all schemas.

defmodule Assistant.Repo do
  use Ecto.Repo,
    otp_app: :assistant,
    adapter: Ecto.Adapters.Postgres
end
