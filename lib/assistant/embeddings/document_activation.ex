defmodule Assistant.Embeddings.DocumentActivation do
  @moduledoc false

  import Ecto.Query
  alias Assistant.Repo
  alias Assistant.Schemas.DocumentFolder

  @spread_rate 0.03
  @max_boost 1.3

  @doc """
  When chunks from a document are retrieved, boost sibling documents
  in the same folder. Non-recursive — only direct folder siblings.
  """
  def spread(retrieved_chunks) when is_list(retrieved_chunks) do
    retrieved_chunks
    |> Enum.group_by(fn chunk ->
      case chunk do
        %{metadata: %{"parent_folder_id" => folder_id}} -> folder_id
        %{metadata: metadata} when is_map(metadata) -> Map.get(metadata, "parent_folder_id")
        _ -> nil
      end
    end)
    |> Enum.each(fn
      {nil, _chunks} -> :skip
      {folder_id, chunks} -> spread_in_folder(folder_id, chunks)
    end)
  end

  def spread(_), do: :ok

  defp spread_in_folder(folder_id, retrieved_chunks) do
    boost = @spread_rate * length(retrieved_chunks)

    from(df in DocumentFolder,
      where: df.drive_folder_id == ^folder_id
    )
    |> Repo.update_all(
      set: [
        activation_boost:
          fragment(
            "LEAST(?, COALESCE(activation_boost, 1.0) + ?)",
            ^@max_boost,
            ^boost
          )
      ]
    )
  end
end
