defmodule Assistant.Repo.Migrations.AddEmailToUsers do
  @moduledoc """
  Adds an email column to the users table for deterministic identity
  matching between settings_users (web dashboard) and chat users.

  Uses citext (already enabled via the settings_users migration) for
  case-insensitive matching. A partial unique index ensures no two users
  share the same email while allowing multiple NULL values.
  """
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :email, :citext
    end

    create unique_index(:users, [:email],
             name: :users_email_unique,
             where: "email IS NOT NULL"
           )
  end
end
