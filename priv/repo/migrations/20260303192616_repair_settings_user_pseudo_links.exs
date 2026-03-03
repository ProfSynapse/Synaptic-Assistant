defmodule Assistant.Repo.Migrations.RepairSettingsUserPseudoLinks do
  @moduledoc """
  Data repair migration: re-links settings_users that were connected to
  "settings" pseudo-users to the actual chat user, when exactly one
  non-settings chat user exists in the system.

  This fixes the cross-channel OAuth key resolution issue where
  `openrouter_key_for_user(channel_user_id)` returned nil because
  `settings_users.user_id` pointed to the pseudo-user, not the real
  chat user.

  Idempotent — safe to run multiple times. Only acts when a single
  non-settings chat user exists.

  Note: `settings_users.user_id` has no unique constraint (multiple
  settings_users may legitimately share the same chat user_id), so the
  UPDATE to a shared `real_chat_user_id` is safe and will not violate
  any DB constraint.
  """
  use Ecto.Migration

  def up do
    # Step 1: Count non-settings chat users. Only proceed if exactly one exists.
    # Step 2: Re-link settings_users from pseudo-user to the real chat user.
    # Step 3: Delete orphaned pseudo-users (and their user_identities via CASCADE).
    execute("""
    DO $$
    DECLARE
      chat_user_count INTEGER;
      real_chat_user_id UUID;
    BEGIN
      -- Count non-settings users
      SELECT COUNT(*) INTO chat_user_count
      FROM users
      WHERE channel IS DISTINCT FROM 'settings';

      -- Only act in single-user setups
      IF chat_user_count = 1 THEN
        -- Get the sole chat user ID
        SELECT id INTO real_chat_user_id
        FROM users
        WHERE channel IS DISTINCT FROM 'settings'
        LIMIT 1;

        -- Re-link settings_users that point to "settings" pseudo-users
        UPDATE settings_users
        SET user_id = real_chat_user_id, updated_at = NOW()
        WHERE user_id IN (
          SELECT id FROM users WHERE channel = 'settings'
        );

        -- Delete orphaned "settings" pseudo-users (user_identities
        -- are cascade-deleted via the FK on_delete: :delete_all)
        DELETE FROM users
        WHERE channel = 'settings'
          AND id NOT IN (
            SELECT user_id FROM settings_users WHERE user_id IS NOT NULL
          );
      END IF;
    END $$;
    """)
  end

  def down do
    # Data repair is not reversible — the pseudo-users are deleted.
    # A fresh ensure_linked_user call will recreate if needed.
    :ok
  end
end
