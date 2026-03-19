defmodule Assistant.Embeddings.EmbedMemoryWorker do
  @moduledoc false
  use Oban.Worker, queue: :embeddings, max_attempts: 3

  alias Assistant.Repo
  alias Assistant.Schemas.MemoryEntry
  alias Assistant.Embeddings

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"memory_entry_id" => entry_id}}) do
    if Embeddings.enabled?() do
      case Repo.get(MemoryEntry, entry_id) do
        nil ->
          {:cancel, "Memory entry #{entry_id} not found"}

        %MemoryEntry{embedding: existing} when not is_nil(existing) ->
          :ok

        %MemoryEntry{content: content} = entry
        when is_binary(content) and byte_size(content) > 0 ->
          case Embeddings.generate(content) do
            {:ok, embedding} ->
              entry
              |> Ecto.Changeset.change(embedding: embedding)
              |> Repo.update()
              |> case do
                {:ok, _} -> :ok
                {:error, changeset} -> {:error, changeset}
              end

            {:error, reason} ->
              {:error, reason}
          end

        _ ->
          {:cancel, "Memory entry #{entry_id} has no content"}
      end
    else
      :ok
    end
  end
end
