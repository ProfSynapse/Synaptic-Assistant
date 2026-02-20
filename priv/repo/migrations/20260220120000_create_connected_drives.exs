defmodule Assistant.Repo.Migrations.CreateConnectedDrives do
  use Ecto.Migration

  def change do
    create table(:connected_drives, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all),
        null: false

      add :drive_id, :string
      add :drive_name, :string, null: false
      add :drive_type, :string, null: false
      add :enabled, :boolean, null: false, default: true

      timestamps(type: :utc_datetime_usec)
    end

    # One row per shared drive per user (drive_id is non-null for shared drives)
    create unique_index(:connected_drives, [:user_id, :drive_id],
      name: :connected_drives_user_drive_unique,
      where: "drive_id IS NOT NULL"
    )

    # At most one personal drive per user (drive_id IS NULL for personal drives)
    create unique_index(:connected_drives, [:user_id],
      name: :connected_drives_user_personal_unique,
      where: "drive_id IS NULL"
    )

    # Fast lookup: all drives for a user
    create index(:connected_drives, [:user_id])
  end
end
