defmodule Assistant.Repo.Migrations.UpdateConversationsForUnified do
  @moduledoc """
  Deduplicates active perpetual conversations, then adds a partial unique
  index for efficient perpetual conversation lookup. Each user has at most
  one active orchestrator conversation (the perpetual "unified" conversation).

  The dedup step is necessary because legacy data may contain multiple active
  orchestrator conversations per user. The newest is kept; duplicates have
  their messages re-parented and are then archived.
  """
  use Ecto.Migration

  def up do
    # Step 0: Update the valid_status CHECK constraint to include 'archived'.
    # The Ecto schema and ConversationArchiver already use 'archived', but
    # the DB constraint was created without it.
    execute("""
    ALTER TABLE conversations DROP CONSTRAINT valid_status
    """)

    execute("""
    ALTER TABLE conversations ADD CONSTRAINT valid_status
      CHECK (status = ANY (ARRAY['active', 'idle', 'closed', 'archived']))
    """)

    # Step 1: Dedup — archive duplicate active orchestrator conversations,
    # keeping the newest per user and re-parenting messages.
    execute("""
    WITH duplicates AS (
      SELECT
        id,
        user_id,
        ROW_NUMBER() OVER (
          PARTITION BY user_id
          ORDER BY updated_at DESC, inserted_at DESC, id DESC
        ) AS rn
      FROM conversations
      WHERE agent_type = 'orchestrator'
        AND status = 'active'
    ),
    to_archive AS (
      SELECT d.id AS old_id, keeper.id AS keeper_id
      FROM duplicates d
      JOIN duplicates keeper
        ON keeper.user_id = d.user_id AND keeper.rn = 1
      WHERE d.rn > 1
    ),
    reparented AS (
      UPDATE messages
      SET conversation_id = ta.keeper_id
      FROM to_archive ta
      WHERE messages.conversation_id = ta.old_id
      RETURNING messages.id
    )
    UPDATE conversations
    SET status = 'archived', updated_at = NOW()
    WHERE id IN (SELECT old_id FROM to_archive)
    """)

    # Step 2: Create the unique partial index (now safe — no duplicates)
    create unique_index(:conversations, [:user_id, :agent_type],
             name: :conversations_user_active_agent_unique,
             where: "status = 'active'"
           )
  end

  def down do
    drop index(:conversations, [:user_id, :agent_type],
           name: :conversations_user_active_agent_unique
         )

    # Restore original CHECK constraint (without 'archived')
    execute("""
    ALTER TABLE conversations DROP CONSTRAINT valid_status
    """)

    execute("""
    ALTER TABLE conversations ADD CONSTRAINT valid_status
      CHECK (status = ANY (ARRAY['active', 'idle', 'closed']))
    """)
  end
end
