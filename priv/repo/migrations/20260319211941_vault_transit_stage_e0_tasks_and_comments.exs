defmodule Assistant.Repo.Migrations.VaultTransitStageE0TasksAndComments do
  use Ecto.Migration

  def change do
    alter table(:tasks) do
      add :description_encrypted, :map
    end

    alter table(:task_comments) do
      add :content_encrypted, :map
    end
  end
end
