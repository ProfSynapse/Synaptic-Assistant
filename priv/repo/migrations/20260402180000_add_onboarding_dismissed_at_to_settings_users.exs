defmodule Assistant.Repo.Migrations.AddOnboardingDismissedAtToSettingsUsers do
  use Ecto.Migration

  def change do
    alter table(:settings_users) do
      add :onboarding_dismissed_at, :utc_datetime, null: true
    end
  end
end
