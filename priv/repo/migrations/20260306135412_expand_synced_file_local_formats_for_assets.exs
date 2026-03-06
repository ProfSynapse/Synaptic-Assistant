defmodule Assistant.Repo.Migrations.ExpandSyncedFileLocalFormatsForAssets do
  use Ecto.Migration

  def up do
    drop constraint(:synced_files, :valid_local_format)

    create constraint(:synced_files, :valid_local_format,
             check:
               "local_format IN ('md', 'csv', 'txt', 'json', 'pdf', 'png', 'jpg', 'webp', 'gif', 'svg', 'bin')"
           )
  end

  def down do
    drop constraint(:synced_files, :valid_local_format)

    create constraint(:synced_files, :valid_local_format,
             check: "local_format IN ('md', 'csv', 'txt', 'json', 'bin')"
           )
  end
end
