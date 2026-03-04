defmodule Assistant.Repo.Migrations.ConsolidatePseudoUsers do
  @moduledoc """
  Data migration: consolidates pseudo-users into real users where an
  email match exists.

  A pseudo-user (channel = 'settings') is created when a settings_user
  logs into the web dashboard before they've ever chatted via a real
  channel. When the same person later chats (e.g., via GChat), a "real"
  user is created with their email. This migration:

  1. Finds settings_users linked to pseudo-users where a real user
     exists with the same email
  2. Re-links settings_user.user_id from pseudo-user to real user
  3. Migrates conversations from pseudo-user to real user
  4. Migrates connected_drives from pseudo-user to real user
  5. Archives the pseudo-user (channel = 'settings_archived')

  Idempotent — only acts on pseudo-users that have a matching real user.
  Does NOT delete pseudo-users — archives them for safety.
  """
  use Ecto.Migration

  def up do
    # Use a PL/pgSQL block for multi-step atomic operation per pseudo-user
    execute("""
    DO $$
    DECLARE
      rec RECORD;
    BEGIN
      -- Find pseudo-users linked via settings_users where a real user
      -- with matching email exists
      FOR rec IN
        SELECT
          su.id AS settings_user_id,
          su.user_id AS pseudo_user_id,
          su.email AS settings_email,
          real_u.id AS real_user_id
        FROM settings_users su
        JOIN users pseudo ON pseudo.id = su.user_id
        JOIN users real_u ON lower(real_u.email) = lower(su.email)
          AND real_u.id != pseudo.id
          AND real_u.channel IS DISTINCT FROM 'settings'
          AND real_u.channel IS DISTINCT FROM 'settings_archived'
        WHERE pseudo.channel = 'settings'
          AND su.user_id IS NOT NULL
      LOOP
        -- 1. Re-link settings_user to the real user
        UPDATE settings_users
        SET user_id = rec.real_user_id, updated_at = NOW()
        WHERE id = rec.settings_user_id;

        -- 2. Migrate conversations: re-assign from pseudo to real user
        --    Skip if real user already has an active orchestrator conversation
        --    (archive pseudo-user's active conversation instead)
        UPDATE conversations
        SET status = 'archived', updated_at = NOW()
        WHERE user_id = rec.pseudo_user_id
          AND agent_type = 'orchestrator'
          AND status = 'active'
          AND EXISTS (
            SELECT 1 FROM conversations
            WHERE user_id = rec.real_user_id
              AND agent_type = 'orchestrator'
              AND status = 'active'
          );

        -- Re-parent messages from pseudo-user's archived active conversation
        -- to real user's active conversation
        UPDATE messages
        SET conversation_id = (
          SELECT id FROM conversations
          WHERE user_id = rec.real_user_id
            AND agent_type = 'orchestrator'
            AND status = 'active'
          LIMIT 1
        )
        WHERE conversation_id IN (
          SELECT id FROM conversations
          WHERE user_id = rec.pseudo_user_id
            AND agent_type = 'orchestrator'
            AND status = 'archived'
            AND updated_at >= NOW() - INTERVAL '1 second'
        )
        AND (
          SELECT id FROM conversations
          WHERE user_id = rec.real_user_id
            AND agent_type = 'orchestrator'
            AND status = 'active'
          LIMIT 1
        ) IS NOT NULL;

        -- Move remaining conversations (non-conflicting) to real user
        UPDATE conversations
        SET user_id = rec.real_user_id, updated_at = NOW()
        WHERE user_id = rec.pseudo_user_id
          AND status != 'archived';

        -- 3. Migrate connected_drives (skip if real user already has them)
        UPDATE connected_drives
        SET user_id = rec.real_user_id, updated_at = NOW()
        WHERE user_id = rec.pseudo_user_id
          AND NOT EXISTS (
            SELECT 1 FROM connected_drives cd2
            WHERE cd2.user_id = rec.real_user_id
              AND cd2.drive_id IS NOT DISTINCT FROM connected_drives.drive_id
          );

        -- 4. Migrate oauth_tokens (skip duplicates)
        UPDATE oauth_tokens
        SET user_id = rec.real_user_id, updated_at = NOW()
        WHERE user_id = rec.pseudo_user_id
          AND NOT EXISTS (
            SELECT 1 FROM oauth_tokens ot2
            WHERE ot2.user_id = rec.real_user_id
              AND ot2.provider = oauth_tokens.provider
          );

        -- 5. Archive the pseudo-user (don't delete — preserves history)
        UPDATE users
        SET channel = 'settings_archived', updated_at = NOW()
        WHERE id = rec.pseudo_user_id;
      END LOOP;
    END $$;
    """)
  end

  def down do
    # Data consolidation — not safely reversible.
    # Archived pseudo-users remain with channel = 'settings_archived'.
    :ok
  end
end
