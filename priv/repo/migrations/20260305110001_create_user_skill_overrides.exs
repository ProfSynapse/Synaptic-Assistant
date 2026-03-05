defmodule Assistant.Repo.Migrations.CreateUserSkillOverrides do
  use Ecto.Migration

  def change do
    create table(:user_skill_overrides, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :skill_name, :string, null: false
      add :enabled, :boolean, null: false, default: true

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:user_skill_overrides, [:user_id, :skill_name],
             name: :user_skill_overrides_user_skill_unique
           )

    create index(:user_skill_overrides, [:user_id])
    create index(:user_skill_overrides, [:skill_name])
  end
end
