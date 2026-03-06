defmodule Assistant.Repo.Migrations.AddFullNameColumns do
  use Ecto.Migration

  def change do
    alter table(:settings_users) do
      add :full_name, :string
    end

    alter table(:settings_user_allowlist_entries) do
      add :full_name, :string
    end
  end
end
