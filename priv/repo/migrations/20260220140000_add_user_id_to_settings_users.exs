defmodule Assistant.Repo.Migrations.AddUserIdToSettingsUsers do
  use Ecto.Migration

  def change do
    alter table(:settings_users) do
      add :user_id, references(:users, type: :binary_id, on_delete: :nilify_all)
    end

    create unique_index(:settings_users, [:user_id],
      name: :settings_users_user_id_unique,
      where: "user_id IS NOT NULL"
    )
  end
end
