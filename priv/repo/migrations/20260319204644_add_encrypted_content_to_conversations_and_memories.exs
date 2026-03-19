defmodule Assistant.Repo.Migrations.AddEncryptedContentToConversationsAndMemories do
  use Ecto.Migration

  def change do
    alter table(:conversations) do
      add :summary_encrypted, :map
    end

    alter table(:memory_entries) do
      add :content_encrypted, :map
    end
  end
end
