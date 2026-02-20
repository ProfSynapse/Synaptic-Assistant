defmodule Assistant.Repo.Migrations.CreateAuthTokens do
  use Ecto.Migration

  def change do
    create table(:auth_tokens, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all),
        null: false

      add :token_hash, :string, null: false
      add :purpose, :string, null: false
      add :code_verifier, :string
      add :oban_job_id, :integer
      add :pending_intent, :binary
      add :expires_at, :utc_datetime_usec, null: false
      add :used_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create constraint(:auth_tokens, :valid_purpose,
      check: "purpose IN ('oauth_google')"
    )

    create unique_index(:auth_tokens, [:token_hash])

    create index(:auth_tokens, [:expires_at])

    # Fast lookup: unused tokens for a user+purpose (magic link validation)
    create index(:auth_tokens, [:user_id, :purpose],
      name: :auth_tokens_user_purpose_unused,
      where: "used_at IS NULL"
    )
  end
end
