defmodule Assistant.Memory.Indexer do
  @moduledoc """
  Handles tokenizing and indexing memory entries into the `content_terms` table
  using the Blind Keyword Index, enabling secure search over encrypted content.
  """

  alias Assistant.Encryption.BlindIndex
  alias Assistant.Schemas.MemoryEntry

  @doc """
  Indexes a memory entry by:
  1. Combining its searchable text components.
  2. Delegating to `BlindIndex.index_content/4` for the actual indexing.
  """
  def index_memory_entry(%MemoryEntry{} = entry, plaintext_content, billing_account_id) do
    # Combine title, content, and search_queries to form the full search corpus
    title = entry.title || ""
    queries = (entry.search_queries || []) |> Enum.join(" ")
    combined_text = [title, plaintext_content, queries] |> Enum.reject(&(&1 in [nil, ""])) |> Enum.join(" ")

    BlindIndex.index_content("memory_entry", entry.id, combined_text, billing_account_id)
  end
end
