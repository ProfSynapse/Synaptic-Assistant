defmodule Assistant.Repo.Migrations.AddSlackToOauthTokens do
  @moduledoc """
  Expands the oauth_tokens provider CHECK constraint to include 'slack' and adds
  workspace metadata fields needed for Slack workspace installations.
  """
  use Ecto.Migration

  def up do
    # Expand provider constraint to include slack
    execute "ALTER TABLE oauth_tokens DROP CONSTRAINT IF EXISTS valid_provider"

    execute "ALTER TABLE oauth_tokens ADD CONSTRAINT valid_provider CHECK (provider IN ('google', 'slack'))"

    # Add Slack workspace metadata columns
    alter table(:oauth_tokens) do
      add :workspace_id, :text
      add :workspace_name, :text
    end
  end

  def down do
    alter table(:oauth_tokens) do
      remove :workspace_name
      remove :workspace_id
    end

    # Restore original constraint (only google)
    execute "ALTER TABLE oauth_tokens DROP CONSTRAINT IF EXISTS valid_provider"

    execute "ALTER TABLE oauth_tokens ADD CONSTRAINT valid_provider CHECK (provider IN ('google'))"
  end
end
