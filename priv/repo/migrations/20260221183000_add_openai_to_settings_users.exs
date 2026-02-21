defmodule Assistant.Repo.Migrations.AddOpenaiToSettingsUsers do
  use Ecto.Migration

  def change do
    alter table(:settings_users) do
      add :openai_api_key, :binary
    end
  end
end
