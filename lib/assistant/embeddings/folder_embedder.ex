defmodule Assistant.Embeddings.FolderEmbedder do
  @moduledoc false

  import Ecto.Query
  alias Assistant.Repo
  alias Assistant.Schemas.DocumentFolder

  @doc """
  Recompute the folder's embedding as the mean of all chunk embeddings
  from documents in this folder. Called after a document is ingested.
  """
  def recompute(user_id, drive_folder_id) do
    child_embeddings =
      from(ac in "arcana_chunks",
        join: ad in "arcana_documents", on: ac.document_id == ad.id,
        where:
          fragment("?->>'parent_folder_id' = ?", ad.metadata, ^drive_folder_id) and
            fragment("?->>'user_id' = ?", ad.metadata, ^to_string(user_id)) and
            not is_nil(ac.embedding),
        select: ac.embedding
      )
      |> Repo.all()

    case child_embeddings do
      [] ->
        :noop

      embeddings ->
        folder_embedding = mean_embedding(embeddings)

        from(df in DocumentFolder,
          where: df.user_id == ^user_id and df.drive_folder_id == ^drive_folder_id
        )
        |> Repo.update_all(
          set: [
            embedding: folder_embedding,
            child_count: length(embeddings),
            updated_at: DateTime.utc_now()
          ]
        )

        :ok
    end
  end

  defp mean_embedding(embeddings) do
    n = length(embeddings)

    embeddings
    |> Enum.map(&Pgvector.to_list/1)
    |> Enum.zip_with(fn vals -> Enum.sum(vals) / n end)
  end
end
