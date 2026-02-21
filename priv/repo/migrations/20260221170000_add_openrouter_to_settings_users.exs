# priv/repo/migrations/20260221170000_add_openrouter_to_settings_users.exs
#
# Adds an encrypted `openrouter_api_key` column to `settings_users`.
# The API key is obtained via OpenRouter's PKCE OAuth flow and stored
# encrypted at rest using Cloak AES-GCM (Assistant.Encrypted.Binary).
#
# Related files:
#   - lib/assistant/accounts/settings_user.ex (schema field)
#   - lib/assistant_web/controllers/openrouter_oauth_controller.ex (OAuth flow)

defmodule Assistant.Repo.Migrations.AddOpenrouterToSettingsUsers do
  use Ecto.Migration

  def change do
    alter table(:settings_users) do
      add :openrouter_api_key, :binary
    end
  end
end
