defmodule Assistant.Memory.Indexer do
  @moduledoc """
  Handles tokenizing and indexing memory entries into the `content_terms` table
  using the Blind Keyword Index, enabling secure search over encrypted content.
  """

  alias Assistant.Repo
  alias Assistant.Encryption.BlindIndex
  alias Assistant.Schemas.MemoryEntry

  import Ecto.Query

  @doc """
  Indexes a memory entry by:
  1. Combining its searchable text components.
  2. Generating hashed term digests via `BlindIndex.process_text/2`.
  3. Replacing any existing rows in `content_terms` for this memory entry.
  """
  def index_memory_entry(%MemoryEntry{} = entry, plaintext_content, billing_account_id) do
    # Combine title, content, and search_queries to form the full search corpus
    title = entry.title || ""
    queries = (entry.search_queries || []) |> Enum.join(" ")
    combined_text = [title, plaintext_content, queries] |> Enum.reject(&(&1 in [nil, ""])) |> Enum.join(" ")

    frequency_map = BlindIndex.process_text(combined_text, billing_account_id)
    
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    # Build the rows for batch insert
    rows =
      Enum.map(frequency_map, fn {digest, count} ->
        %{
          id: Ecto.UUID.generate(),
          billing_account_id: billing_account_id,
          owner_type: "memory_entry",
          owner_id: entry.id,
          field: "all",
          term_digest: digest,
          term_frequency: count,
          inserted_at: now,
          updated_at: now
        }
      end)

    # Transactionally clear out old terms and insert the new ones
    Repo.transaction(fn ->
      from(c in "content_terms",
        where: c.owner_type == "memory_entry" and c.owner_id == ^entry.id
      )
      |> Repo.delete_all()

      unless Enum.empty?(rows) do
        Repo.insert_all("content_terms", rows)
      end
    end)
    
    :ok
  end
end
