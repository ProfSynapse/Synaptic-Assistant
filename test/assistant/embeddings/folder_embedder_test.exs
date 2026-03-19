defmodule Assistant.Embeddings.FolderEmbedderTest do
  use Assistant.DataCase, async: false

  import Assistant.MemoryFixtures
  alias Assistant.Embeddings.FolderEmbedder
  alias Assistant.Schemas.DocumentFolder

  # We need arcana_chunks and arcana_documents tables for FolderEmbedder.
  # These don't exist in the main app migrations, so we create them
  # transiently within the sandboxed transaction.

  setup do
    Repo.query!("""
    CREATE TABLE IF NOT EXISTS arcana_documents (
      id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
      content text,
      content_type varchar(255) DEFAULT 'text/plain',
      source_id varchar(255),
      file_path varchar(255),
      metadata jsonb DEFAULT '{}',
      status varchar(255) DEFAULT 'pending',
      error text,
      chunk_count integer DEFAULT 0,
      inserted_at timestamp DEFAULT now(),
      updated_at timestamp DEFAULT now()
    )
    """)

    Repo.query!("""
    CREATE TABLE IF NOT EXISTS arcana_chunks (
      id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
      text text NOT NULL,
      embedding vector(384) NOT NULL,
      chunk_index integer DEFAULT 0,
      token_count integer,
      metadata jsonb DEFAULT '{}',
      document_id uuid REFERENCES arcana_documents(id) ON DELETE CASCADE,
      inserted_at timestamp DEFAULT now(),
      updated_at timestamp DEFAULT now()
    )
    """)

    :ok
  end

  defp fake_embedding(seed) do
    :rand.seed(:exsss, {seed, seed, seed})
    raw = for _ <- 1..384, do: :rand.uniform() * 2 - 1
    norm = :math.sqrt(Enum.reduce(raw, 0.0, fn x, acc -> acc + x * x end))
    Enum.map(raw, &(&1 / norm))
  end

  defp insert_arcana_document!(metadata) when is_map(metadata) do
    doc_id = Ecto.UUID.generate()

    Repo.query!(
      "INSERT INTO arcana_documents (id, content, metadata) VALUES ($1, $2, $3)",
      [Ecto.UUID.dump!(doc_id), "test content", metadata]
    )

    doc_id
  end

  defp insert_arcana_chunk!(document_id, embedding) do
    chunk_id = Ecto.UUID.generate()
    pgvec = Pgvector.new(embedding)

    Repo.query!(
      "INSERT INTO arcana_chunks (id, text, embedding, document_id) VALUES ($1, $2, $3, $4)",
      [Ecto.UUID.dump!(chunk_id), "chunk text", pgvec, Ecto.UUID.dump!(document_id)]
    )

    chunk_id
  end

  defp create_folder!(user, drive_folder_id, name) do
    {:ok, folder} =
      DocumentFolder.upsert(%{
        drive_folder_id: drive_folder_id,
        name: name,
        user_id: user.id
      })

    folder
  end

  describe "module compilation" do
    test "module is loaded and exports recompute/2" do
      Code.ensure_loaded!(FolderEmbedder)
      assert function_exported?(FolderEmbedder, :recompute, 2)
    end
  end

  describe "recompute/2 with no matching chunks" do
    test "returns :noop when no arcana chunks exist for folder" do
      user = user_fixture()
      _folder = create_folder!(user, "empty-folder", "Empty Folder")

      assert :noop = FolderEmbedder.recompute(user.id, "empty-folder")
    end

    test "returns :noop when folder has no matching user_id" do
      user = user_fixture()
      other_user = user_fixture()
      _folder = create_folder!(user, "folder-x", "Folder X")

      metadata = %{"parent_folder_id" => "folder-x", "user_id" => to_string(other_user.id)}
      doc_id = insert_arcana_document!(metadata)
      insert_arcana_chunk!(doc_id, fake_embedding(1))

      assert :noop = FolderEmbedder.recompute(user.id, "folder-x")
    end

    test "returns :noop when chunks exist for different folder_id" do
      user = user_fixture()
      _folder = create_folder!(user, "target-folder", "Target")

      metadata = %{"parent_folder_id" => "other-folder", "user_id" => to_string(user.id)}
      doc_id = insert_arcana_document!(metadata)
      insert_arcana_chunk!(doc_id, fake_embedding(5))

      assert :noop = FolderEmbedder.recompute(user.id, "target-folder")
    end
  end

  describe "recompute/2 with matching chunks" do
    test "computes mean embedding from a single chunk and updates folder" do
      user = user_fixture()
      folder = create_folder!(user, "folder-single", "Single Chunk Folder")

      embedding = fake_embedding(42)
      metadata = %{"parent_folder_id" => "folder-single", "user_id" => to_string(user.id)}
      doc_id = insert_arcana_document!(metadata)
      insert_arcana_chunk!(doc_id, embedding)

      assert :ok = FolderEmbedder.recompute(user.id, "folder-single")

      updated = Repo.get!(DocumentFolder, folder.id)
      assert updated.child_count == 1
      assert updated.embedding != nil

      # Single chunk: mean embedding == the chunk embedding itself
      stored = Pgvector.to_list(updated.embedding)

      for {expected, actual} <- Enum.zip(embedding, stored) do
        assert_in_delta expected, actual, 1.0e-5
      end
    end

    test "computes correct mean embedding from multiple chunks" do
      user = user_fixture()
      folder = create_folder!(user, "folder-multi", "Multi Chunk Folder")

      emb1 = fake_embedding(100)
      emb2 = fake_embedding(200)
      metadata = %{"parent_folder_id" => "folder-multi", "user_id" => to_string(user.id)}

      doc1 = insert_arcana_document!(metadata)
      insert_arcana_chunk!(doc1, emb1)
      doc2 = insert_arcana_document!(metadata)
      insert_arcana_chunk!(doc2, emb2)

      assert :ok = FolderEmbedder.recompute(user.id, "folder-multi")

      updated = Repo.get!(DocumentFolder, folder.id)
      assert updated.child_count == 2

      # Mean of two embeddings, then L2-normalized
      raw_mean = Enum.zip_with(emb1, emb2, fn a, b -> (a + b) / 2 end)
      magnitude = :math.sqrt(Enum.reduce(raw_mean, 0.0, fn x, acc -> acc + x * x end))
      expected = Enum.map(raw_mean, &(&1 / magnitude))
      stored = Pgvector.to_list(updated.embedding)

      for {exp, actual} <- Enum.zip(expected, stored) do
        assert_in_delta exp, actual, 1.0e-5
      end
    end
  end

  describe "recompute/2 query filtering" do
    test "query correctly filters by user_id and parent_folder_id" do
      user = user_fixture()
      other_user = user_fixture()

      # Seed data for both users in the same folder name
      meta_user = %{"parent_folder_id" => "shared-folder", "user_id" => to_string(user.id)}
      meta_other = %{"parent_folder_id" => "shared-folder", "user_id" => to_string(other_user.id)}

      doc_user = insert_arcana_document!(meta_user)
      insert_arcana_chunk!(doc_user, fake_embedding(1))

      doc_other = insert_arcana_document!(meta_other)
      insert_arcana_chunk!(doc_other, fake_embedding(2))

      # Verify the raw query returns correct count for each user
      result =
        Repo.query!(
          """
          SELECT COUNT(*) FROM arcana_chunks ac
          INNER JOIN arcana_documents ad ON ac.document_id = ad.id
          WHERE ad.metadata->>'parent_folder_id' = $1
            AND ad.metadata->>'user_id' = $2
            AND ac.embedding IS NOT NULL
          """,
          ["shared-folder", to_string(user.id)]
        )

      [[count]] = result.rows
      assert count == 1

      result_other =
        Repo.query!(
          """
          SELECT COUNT(*) FROM arcana_chunks ac
          INNER JOIN arcana_documents ad ON ac.document_id = ad.id
          WHERE ad.metadata->>'parent_folder_id' = $1
            AND ad.metadata->>'user_id' = $2
            AND ac.embedding IS NOT NULL
          """,
          ["shared-folder", to_string(other_user.id)]
        )

      [[other_count]] = result_other.rows
      assert other_count == 1
    end
  end
end
