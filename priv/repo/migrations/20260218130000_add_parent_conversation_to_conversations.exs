defmodule Assistant.Repo.Migrations.AddParentConversationToConversations do
  @moduledoc """
  Adds sub-agent conversation support to the conversations table.

  Sub-agents run their own LLM loops and need their own conversation_id.
  The orchestrator's conversation is the root (parent_conversation_id = NULL).
  Sub-agent conversations are children that reference their parent.

  New columns:
    - parent_conversation_id: self-referencing FK for parent/child hierarchy
    - agent_type: distinguishes orchestrator conversations from sub-agent ones
  """
  use Ecto.Migration

  def change do
    alter table(:conversations) do
      add :parent_conversation_id,
          references(:conversations, type: :binary_id, on_delete: :delete_all)

      add :agent_type, :text, null: false, default: "orchestrator"
    end

    create constraint(:conversations, :valid_agent_type,
             check: "agent_type IN ('orchestrator', 'sub_agent')"
           )

    # Efficient lookup of child conversations by parent
    create index(:conversations, [:parent_conversation_id],
             where: "parent_conversation_id IS NOT NULL"
           )

    # Find all sub-agent conversations (useful for cleanup, auditing)
    create index(:conversations, [:agent_type],
             where: "agent_type = 'sub_agent'"
           )
  end
end
