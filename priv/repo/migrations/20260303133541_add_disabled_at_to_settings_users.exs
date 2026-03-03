defmodule Assistant.Repo.Migrations.AddDisabledAtToSettingsUsers do
  use Ecto.Migration

  def change do
    alter table(:settings_users) do
      add :disabled_at, :utc_datetime
    end
  end
end
