defmodule Assistant.Repo.Migrations.AddModelDefaultsToSettingsUsers do
  use Ecto.Migration

  def change do
    alter table(:settings_users) do
      add :model_defaults, :map, null: false, default: %{}
      add :can_manage_model_defaults, :boolean, null: false, default: false
    end
  end
end
