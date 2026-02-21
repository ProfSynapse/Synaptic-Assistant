defmodule Assistant.Repo.Migrations.AddAgentResultToSourceTypeConstraint do
  use Ecto.Migration

  def up do
    # Drop the old CHECK constraint that does not include 'agent_result'
    drop constraint(:memory_entries, :valid_source_type)

    # Re-create with 'agent_result' added to the allowed values
    create constraint(:memory_entries, :valid_source_type,
             check:
               "source_type IS NULL OR source_type IN ('conversation', 'skill_execution', 'user_explicit', 'system', 'agent_result')"
           )
  end

  def down do
    drop constraint(:memory_entries, :valid_source_type)

    create constraint(:memory_entries, :valid_source_type,
             check:
               "source_type IS NULL OR source_type IN ('conversation', 'skill_execution', 'user_explicit', 'system')"
           )
  end
end
