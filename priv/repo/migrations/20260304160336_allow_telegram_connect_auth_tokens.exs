defmodule Assistant.Repo.Migrations.AllowTelegramConnectAuthTokens do
  use Ecto.Migration

  def change do
    drop constraint(:auth_tokens, :valid_purpose)

    create constraint(:auth_tokens, :valid_purpose,
             check: "purpose IN ('oauth_google', 'telegram_connect')"
           )
  end
end
