defmodule Assistant.Embeddings.EmbedMemoryWorkerTest do
  use Assistant.DataCase, async: false

  import Assistant.MemoryFixtures
  alias Assistant.Embeddings.EmbedMemoryWorker

  describe "module compilation" do
    test "module is loaded and defines Oban callbacks" do
      assert Code.ensure_loaded?(EmbedMemoryWorker)
      assert function_exported?(EmbedMemoryWorker, :perform, 1)
      assert function_exported?(EmbedMemoryWorker, :new, 1)
    end
  end

  describe "new/1 changeset" do
    test "builds valid Oban job changeset" do
      changeset = EmbedMemoryWorker.new(%{memory_entry_id: Ecto.UUID.generate()})
      assert %Ecto.Changeset{} = changeset
      assert changeset.valid?
    end

    test "job uses embeddings queue" do
      changeset = EmbedMemoryWorker.new(%{memory_entry_id: Ecto.UUID.generate()})
      assert changeset.changes[:queue] == "embeddings"
    end

    test "max attempts is 3" do
      changeset = EmbedMemoryWorker.new(%{memory_entry_id: Ecto.UUID.generate()})
      assert changeset.changes[:max_attempts] == 3
    end
  end

  describe "perform/1 with embeddings disabled" do
    test "returns :ok without doing anything when embeddings disabled" do
      user = user_fixture()
      entry = memory_fixture!(user, "Test memory content")

      job = %Oban.Job{args: %{"memory_entry_id" => entry.id}}
      assert :ok = EmbedMemoryWorker.perform(job)

      # Entry should NOT have an embedding (disabled)
      reloaded = Repo.get!(Assistant.Schemas.MemoryEntry, entry.id)
      assert is_nil(reloaded.embedding)
    end
  end

  describe "perform/1 error cases" do
    test "returns cancel for non-existent entry" do
      original = Application.get_env(:assistant, :embeddings, [])
      Application.put_env(:assistant, :embeddings, enabled: true)
      on_exit(fn -> Application.put_env(:assistant, :embeddings, original) end)

      job = %Oban.Job{args: %{"memory_entry_id" => Ecto.UUID.generate()}}
      assert {:cancel, _reason} = EmbedMemoryWorker.perform(job)
    end

    test "returns cancel for entry with empty content" do
      original = Application.get_env(:assistant, :embeddings, [])
      Application.put_env(:assistant, :embeddings, enabled: true)
      on_exit(fn -> Application.put_env(:assistant, :embeddings, original) end)

      user = user_fixture()

      # Insert directly with empty content to bypass changeset content validation
      {:ok, entry} =
        %Assistant.Schemas.MemoryEntry{}
        |> Ecto.Changeset.change(%{user_id: user.id, content: "", title: "Empty test"})
        |> Repo.insert()

      job = %Oban.Job{args: %{"memory_entry_id" => entry.id}}
      # Empty content (byte_size 0) fails the guard, falls to cancel
      assert {:cancel, _reason} = EmbedMemoryWorker.perform(job)
    end
  end
end
