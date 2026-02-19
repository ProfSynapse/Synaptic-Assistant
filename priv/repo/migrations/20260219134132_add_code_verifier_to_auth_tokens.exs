# priv/repo/migrations/20260219134132_add_code_verifier_to_auth_tokens.exs
#
# Adds code_verifier column to auth_tokens for PKCE persistence.
# Replaces ETS-based PKCE storage with database-backed storage,
# ensuring code_verifiers survive process restarts and multi-node deploys.

defmodule Assistant.Repo.Migrations.AddCodeVerifierToAuthTokens do
  use Ecto.Migration

  def change do
    alter table(:auth_tokens) do
      add :code_verifier, :text
    end
  end
end
