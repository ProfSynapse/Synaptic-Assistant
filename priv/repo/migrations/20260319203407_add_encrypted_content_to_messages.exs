defmodule Assistant.Repo.Migrations.AddEncryptedContentToMessages do
  use Ecto.Migration

  def change do
    alter table(:messages) do
      add :content_encrypted, :map
    end
  end
end
