defmodule Assistant.Repo.Migrations.CreateSyncCursors do
  use Ecto.Migration

  def change do
    create table(:sync_cursors, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false

      add :drive_id, :string
      add :start_page_token, :string, null: false
      add :last_poll_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    # One cursor per drive per user (drive_id non-null for shared drives)
    create unique_index(:sync_cursors, [:user_id, :drive_id],
             name: :sync_cursors_user_drive_unique,
             where: "drive_id IS NOT NULL"
           )

    # At most one cursor for personal drive per user (drive_id IS NULL)
    create unique_index(:sync_cursors, [:user_id],
             name: :sync_cursors_user_personal_unique,
             where: "drive_id IS NULL"
           )

    create index(:sync_cursors, [:user_id])
  end
end
