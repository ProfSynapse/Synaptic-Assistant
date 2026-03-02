defmodule Assistant.Repo.Migrations.AddBinToLocalFormatConstraint do
  use Ecto.Migration

  def change do
    # Drop old constraint and recreate with "bin" included
    drop constraint(:synced_files, :valid_local_format)

    create constraint(:synced_files, :valid_local_format,
             check: "local_format IN ('md', 'csv', 'txt', 'json', 'bin')"
           )
  end
end
