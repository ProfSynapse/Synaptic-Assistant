defmodule Assistant.Repo.Migrations.BackfillUserIdentities do
  @moduledoc """
  Data migration: backfill user_identities from existing users rows, then
  drop the UNIQUE(external_id, channel) constraint on users since
  user_identities is now the authoritative identity table.
  """
  use Ecto.Migration

  def up do
    # Backfill: copy each user's primary identity into user_identities.
    # ON CONFLICT DO NOTHING handles re-runs safely.
    execute("""
    INSERT INTO user_identities (id, user_id, channel, external_id, inserted_at, updated_at)
    SELECT
      gen_random_uuid(),
      u.id,
      u.channel,
      u.external_id,
      NOW(),
      NOW()
    FROM users u
    ON CONFLICT DO NOTHING
    """)

    # Drop the unique constraint on users (external_id, channel).
    # user_identities is now authoritative for identity lookups.
    drop unique_index(:users, [:external_id, :channel])
  end

  def down do
    # Restore the unique constraint on users
    create unique_index(:users, [:external_id, :channel])

    # Remove backfilled identities (only those that exactly match a user's primary identity)
    execute("""
    DELETE FROM user_identities ui
    USING users u
    WHERE ui.user_id = u.id
      AND ui.channel = u.channel
      AND ui.external_id = u.external_id
      AND ui.space_id IS NULL
    """)
  end
end
