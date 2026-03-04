defmodule Assistant.Repo.Migrations.AddMetadataToMessages do
  use Ecto.Migration

  def change do
    alter table(:messages) do
      add :metadata, :map, default: %{}, null: false
    end
  end
end
