defmodule Assistant.Embeddings.EmbedDocumentWorkerTest do
  use ExUnit.Case, async: true

  alias Assistant.Embeddings.EmbedDocumentWorker

  describe "module compilation" do
    test "module is loaded and defines Oban callbacks" do
      assert Code.ensure_loaded?(EmbedDocumentWorker)
      assert function_exported?(EmbedDocumentWorker, :perform, 1)
      assert function_exported?(EmbedDocumentWorker, :new, 1)
    end
  end

  describe "new/1 changeset" do
    test "builds valid Oban job changeset" do
      changeset = EmbedDocumentWorker.new(%{synced_file_id: Ecto.UUID.generate()})
      assert %Ecto.Changeset{} = changeset
      assert changeset.valid?
    end

    test "job uses embeddings queue" do
      changeset = EmbedDocumentWorker.new(%{synced_file_id: Ecto.UUID.generate()})
      assert changeset.changes[:queue] == "embeddings"
    end

    test "max attempts is 3" do
      changeset = EmbedDocumentWorker.new(%{synced_file_id: Ecto.UUID.generate()})
      assert changeset.changes[:max_attempts] == 3
    end
  end

  describe "perform/1 with embeddings disabled" do
    test "returns :ok without doing anything" do
      job = %Oban.Job{args: %{"synced_file_id" => Ecto.UUID.generate()}}
      assert :ok = EmbedDocumentWorker.perform(job)
    end
  end
end
