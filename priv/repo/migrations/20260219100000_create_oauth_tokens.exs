defmodule Assistant.Repo.Migrations.CreateOauthTokens do
  @moduledoc """
  Creates the oauth_tokens table for per-user OAuth2 token storage.

  Stores encrypted refresh and access tokens per user/provider pair.
  Designed for multi-provider support (currently Google only).

  Encryption: refresh_token and access_token are stored as :binary (BYTEA)
  and encrypted/decrypted transparently by Cloak.Ecto via Assistant.Encrypted.Binary.
  """
  use Ecto.Migration

  def change do
    create table(:oauth_tokens, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all),
        null: false

      add :provider, :text, null: false
      add :provider_uid, :text
      add :provider_email, :text
      add :refresh_token, :binary, null: false
      add :access_token, :binary
      add :token_expires_at, :utc_datetime_usec
      add :scopes, :text

      timestamps(type: :utc_datetime_usec)
    end

    create constraint(:oauth_tokens, :valid_provider,
             check: "provider IN ('google')"
           )

    create unique_index(:oauth_tokens, [:user_id, :provider])
    create index(:oauth_tokens, [:provider])
  end
end
