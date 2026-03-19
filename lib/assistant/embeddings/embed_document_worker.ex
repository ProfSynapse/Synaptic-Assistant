defmodule Assistant.Embeddings.EmbedDocumentWorker do
  @moduledoc false
  use Oban.Worker, queue: :embeddings, max_attempts: 3

  alias Assistant.Repo
  alias Assistant.Schemas.SyncedFile
  alias Assistant.Embeddings
  alias Assistant.Embeddings.FolderEmbedder

  @text_formats ~w(md csv txt json)

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"synced_file_id" => file_id}}) do
    if Embeddings.enabled?() do
      case Repo.get(SyncedFile, file_id) do
        nil ->
          {:cancel, "Synced file #{file_id} not found"}

        %SyncedFile{local_format: format} when format not in @text_formats ->
          {:cancel, "Non-text format: #{format}"}

        %SyncedFile{content: nil} ->
          {:cancel, "Synced file #{file_id} has no content"}

        %SyncedFile{} = file ->
          ingest_document(file)
      end
    else
      :ok
    end
  end

  defp ingest_document(%SyncedFile{} = file) do
    content = decrypt_content(file.content)

    if is_binary(content) and byte_size(content) > 0 do
      metadata = %{
        user_id: to_string(file.user_id),
        file_name: file.drive_file_name,
        mime_type: file.drive_mime_type,
        drive_id: file.drive_id,
        parent_folder_id: file.parent_folder_id,
        parent_folder_name: file.parent_folder_name
      }

      # Delete existing document for this source, then re-ingest
      with :ok <- delete_existing(file.drive_file_id),
           {:ok, _doc} <- do_ingest(content, file.drive_file_id, metadata) do
        # Recompute folder embedding if document has a parent folder
        maybe_recompute_folder(file)
        :ok
      end
    else
      {:cancel, "Empty content after decryption"}
    end
  end

  defp delete_existing(source_id) do
    # Arcana.delete_by_source_id would go here
    # For now, we handle this at the Arcana API level
    _ = source_id
    :ok
  end

  defp do_ingest(content, source_id, metadata) do
    # Arcana.ingest(content, collection: "user_documents", source_id: source_id, metadata: metadata)
    # Stubbed until Arcana is installed
    _ = {content, source_id, metadata}
    {:ok, %{}}
  end

  defp maybe_recompute_folder(%SyncedFile{parent_folder_id: nil}), do: :ok

  defp maybe_recompute_folder(%SyncedFile{user_id: user_id, parent_folder_id: folder_id}) do
    FolderEmbedder.recompute(user_id, folder_id)
  end

  defp decrypt_content(content) when is_binary(content), do: content
  defp decrypt_content(_), do: nil
end
