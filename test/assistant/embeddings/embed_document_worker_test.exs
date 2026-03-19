defmodule Assistant.Embeddings.EmbedDocumentWorkerTest do
  use Assistant.DataCase, async: true

  import Assistant.MemoryFixtures
  alias Assistant.Embeddings.EmbedDocumentWorker
  alias Assistant.Schemas.SyncedFile

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

  describe "perform/1 with embeddings enabled but SyncedFile missing" do
    setup do
      original = Application.get_env(:assistant, :embeddings, [])
      Application.put_env(:assistant, :embeddings, enabled: true)
      on_exit(fn -> Application.put_env(:assistant, :embeddings, original) end)
      :ok
    end

    test "returns {:cancel, _} when synced_file_id not in DB" do
      fake_id = Ecto.UUID.generate()
      job = %Oban.Job{args: %{"synced_file_id" => fake_id}}
      assert {:cancel, msg} = EmbedDocumentWorker.perform(job)
      assert msg =~ "not found"
    end
  end

  describe "perform/1 with embeddings enabled — format filtering" do
    setup do
      original = Application.get_env(:assistant, :embeddings, [])
      Application.put_env(:assistant, :embeddings, enabled: true)
      on_exit(fn -> Application.put_env(:assistant, :embeddings, original) end)
      :ok
    end

    test "cancels for non-text formats (e.g., pdf, png)" do
      user = user_fixture()

      for format <- ["pdf", "png", "jpg", "bin"] do
        {:ok, sf} =
          %SyncedFile{}
          |> SyncedFile.changeset(%{
            user_id: user.id,
            drive_file_id: "file-#{format}-#{System.unique_integer([:positive])}",
            drive_file_name: "test.#{format}",
            drive_mime_type: "application/octet-stream",
            local_path: "/tmp/test.#{format}",
            local_format: format,
            content: "some content"
          })
          |> Repo.insert()

        job = %Oban.Job{args: %{"synced_file_id" => sf.id}}
        assert {:cancel, msg} = EmbedDocumentWorker.perform(job)
        assert msg =~ "Non-text format"
      end
    end

    test "proceeds for text formats (md, txt, csv, json)" do
      user = user_fixture()

      for format <- ["md", "txt", "csv", "json"] do
        {:ok, sf} =
          %SyncedFile{}
          |> SyncedFile.changeset(%{
            user_id: user.id,
            drive_file_id: "file-#{format}-#{System.unique_integer([:positive])}",
            drive_file_name: "test.#{format}",
            drive_mime_type: "text/plain",
            local_path: "/tmp/test.#{format}",
            local_format: format,
            content: "Real content here"
          })
          |> Repo.insert()

        job = %Oban.Job{args: %{"synced_file_id" => sf.id}}
        # Should NOT return {:cancel, "Non-text format: ..."}
        result = EmbedDocumentWorker.perform(job)
        refute match?({:cancel, "Non-text format:" <> _}, result)
      end
    end
  end

  describe "perform/1 with embeddings enabled — nil content" do
    setup do
      original = Application.get_env(:assistant, :embeddings, [])
      Application.put_env(:assistant, :embeddings, enabled: true)
      on_exit(fn -> Application.put_env(:assistant, :embeddings, original) end)
      :ok
    end

    test "cancels when SyncedFile has nil content" do
      user = user_fixture()

      {:ok, sf} =
        %SyncedFile{}
        |> SyncedFile.changeset(%{
          user_id: user.id,
          drive_file_id: "nil-content-#{System.unique_integer([:positive])}",
          drive_file_name: "empty.md",
          drive_mime_type: "text/markdown",
          local_path: "/tmp/empty.md",
          local_format: "md"
        })
        |> Repo.insert()

      # content is nil since we didn't set it
      job = %Oban.Job{args: %{"synced_file_id" => sf.id}}
      assert {:cancel, msg} = EmbedDocumentWorker.perform(job)
      assert msg =~ "no content"
    end
  end
end
