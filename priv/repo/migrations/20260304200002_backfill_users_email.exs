defmodule Assistant.Repo.Migrations.BackfillUsersEmail do
  @moduledoc """
  Data migration: backfills users.email from two sources:

  1. settings_users — where settings_users.user_id links to users.id
  2. user_identities metadata — where GChat stores user_email in metadata

  Idempotent — only updates rows where users.email IS NULL.
  settings_users is the primary/trusted source; metadata is fallback.
  """
  use Ecto.Migration

  def up do
    # Source 1: Backfill from settings_users (trusted, canonical)
    execute("""
    UPDATE users
    SET email = su.email, updated_at = NOW()
    FROM settings_users su
    WHERE su.user_id = users.id
      AND users.email IS NULL
      AND su.email IS NOT NULL
    """)

    # Source 2: Backfill from user_identities GChat metadata
    # GChat webhook stores email in metadata as "user_email"
    execute("""
    UPDATE users
    SET email = ui.metadata->>'user_email', updated_at = NOW()
    FROM user_identities ui
    WHERE ui.user_id = users.id
      AND users.email IS NULL
      AND ui.metadata->>'user_email' IS NOT NULL
      AND ui.channel = 'google_chat'
    """)
  end

  def down do
    # Data backfill — not safely reversible without knowing original state.
    # The email column itself is removed by rolling back migration 200001.
    :ok
  end
end
