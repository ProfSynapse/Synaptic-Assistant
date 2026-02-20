defmodule Assistant.Repo.Migrations.CreateOauthTokens do
  use Ecto.Migration

  def change do
    create table(:oauth_tokens, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all),
        null: false

      add :provider, :string, null: false
      add :provider_uid, :string
      add :provider_email, :string
      add :refresh_token, :binary, null: false
      add :access_token, :binary
      add :token_expires_at, :utc_datetime_usec
      add :scopes, :string

      timestamps(type: :utc_datetime_usec)
    end

    create constraint(:oauth_tokens, :valid_provider,
      check: "provider IN ('google')"
    )

    # One token per user per provider
    create unique_index(:oauth_tokens, [:user_id, :provider])
  end
end
