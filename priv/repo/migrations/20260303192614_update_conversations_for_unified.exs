defmodule Assistant.Repo.Migrations.UpdateConversationsForUnified do
  @moduledoc """
  Adds a partial index on conversations for efficient perpetual conversation
  lookup. Each user has at most one active orchestrator conversation (the
  perpetual "unified" conversation).
  """
  use Ecto.Migration

  def change do
    # Fast lookup for get_or_create_perpetual_conversation:
    # SELECT ... FROM conversations WHERE user_id = ? AND agent_type = 'orchestrator' AND status = 'active'
    create unique_index(:conversations, [:user_id, :agent_type],
             name: :conversations_user_active_agent_unique,
             where: "status = 'active'"
           )
  end
end
