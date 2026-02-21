defmodule Assistant.Repo.Migrations.CreateAuthTokens do
  @moduledoc """
  Creates the auth_tokens table for magic link token storage.

  Magic link tokens are single-use, time-limited tokens used to initiate
  OAuth2 flows. The raw token is never stored — only its SHA-256 hash.

  The oban_job_id column links to a parked PendingIntentWorker Oban job
  that will replay the user's original command after OAuth completes.
  """
  use Ecto.Migration

  def change do
    create table(:auth_tokens, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false

      add :token_hash, :text, null: false
      add :purpose, :text, null: false
      add :oban_job_id, :bigint
      add :expires_at, :utc_datetime_usec, null: false
      add :used_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create constraint(:auth_tokens, :valid_purpose, check: "purpose IN ('oauth_google')")

    create unique_index(:auth_tokens, [:token_hash])
    create index(:auth_tokens, [:expires_at])

    create index(:auth_tokens, [:user_id, :purpose],
             where: "used_at IS NULL",
             name: :idx_auth_tokens_user_purpose_unused
           )
  end
end
