defmodule Assistant.Repo.Migrations.AddOpenaiOauthFieldsToSettingsUsers do
  use Ecto.Migration

  def change do
    alter table(:settings_users) do
      add :openai_refresh_token, :binary
      add :openai_account_id, :string
      add :openai_expires_at, :utc_datetime
      add :openai_auth_type, :string
    end
  end
end
