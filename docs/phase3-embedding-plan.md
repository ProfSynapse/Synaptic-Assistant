# Phase 3: Local Embeddings + Semantic Search (via Arcana)

## Overview

Add local embedding generation and semantic search using **Arcana** as the RAG backbone, with a **custom semantic chunker** that detects topic boundaries via embedding similarity drops. Fully in-process, no external APIs, no GPU required.

## Architecture

```
                    ┌─────────────────────────┐
                    │  Shared Nx.Serving       │
                    │  (gte-small, 384D)       │
                    │  Used by Arcana +        │
                    │  SemanticChunker +       │
                    │  Memory embeddings       │
                    └────────────┬────────────┘
                                 │
           ┌─────────────────────┼─────────────────────┐
           ▼                     ▼                      ▼
    Memory.Store          FileSyncWorker          Skills (search)
    .create_entry()       .sync_file()            .execute()
           │                     │                      │
           ▼                     ▼                      ▼
    ┌────────────┐    ┌──────────────────┐    ┌──────────────────┐
    │ memory_    │    │ Arcana Pipeline   │    │ Unified Search   │
    │ entries    │    │ SemanticChunker → │    │ memory hybrid +  │
    │ +embedding │    │ Embed → pgvector  │    │ arcana hybrid    │
    └────────────┘    └──────────────────┘    └──────────────────┘
           │                     │                      │
           └─────────────────────┼──────────────────────┘
                                 ▼
                       PostgreSQL + pgvector
```

## Dependencies

```elixir
# mix.exs
{:arcana, "~> 1.3"},         # RAG backbone (bundles text_chunker, pgvector, bumblebee)
{:exla, "~> 0.9"},           # XLA backend for Nx (CPU)
```

Arcana pulls in `bumblebee`, `pgvector`, `text_chunker`, `nx` as transitive deps. We add only 2 direct deps.

## Key Design Decisions

### 1. Arcana for documents, custom for memories

- **Documents** → Arcana's full pipeline (ingest → chunk → embed → store → search)
- **Memory entries** → Direct embedding on the existing `memory_entries` table (memories are already atomic units, no chunking needed)
- **Unified search** → Fan out to both, merge via RRF

Why: Arcana's `arcana_collections/documents/chunks` schema is perfect for documents. But memory entries are small, already have FTS + importance scoring, and live in their own table — shoehorning them into Arcana's schema would lose the importance/decay/access metadata.

### 2. Semantic chunking via custom `Arcana.Chunker`

Instead of fixed-size windows, we implement **embedding-based boundary detection**:

```
Document → split into sentences → batch-embed all sentences →
compare adjacent embeddings → similarity drops = topic boundaries →
group sentences between boundaries into chunks
```

This produces variable-size chunks that align with actual topic shifts. The `Arcana.Chunker` behaviour makes this a clean plug-in.

### 3. Single shared Nx.Serving

Both Arcana and our memory embedding code share one `Nx.Serving` for gte-small. We write a thin `Arcana.Embedder` adapter that delegates to our serving, avoiding double-loading the 70MB model.

---

## Implementation Phases

### Phase 3a: Foundation

**Goal**: Deps, pgvector, Bumblebee serving, Arcana installed. No behavior change.

#### 1. Add deps + run `mix arcana.install`

This generates:
- pgvector extension migration
- `arcana_collections`, `arcana_documents`, `arcana_chunks` tables
- Postgrex type registration for `Pgvector.Extensions.Vector`

#### 2. Shared Bumblebee serving

New module: `lib/assistant/embeddings/serving.ex`

```elixir
defmodule Assistant.Embeddings.Serving do
  @moduledoc false

  def child_spec(_opts) do
    model_repo = {:hf, "thenlper/gte-small"}
    {:ok, model_info} = Bumblebee.load_model(model_repo)
    {:ok, tokenizer} = Bumblebee.load_tokenizer(model_repo)

    serving =
      Bumblebee.Text.TextEmbedding.text_embedding(model_info, tokenizer,
        output_pool: :mean_pooling,
        output_attribute: :hidden_state,
        embedding_processor: :l2_norm,
        compile: [batch_size: 32, sequence_length: 512],
        defn_options: [compiler: EXLA]
      )

    {Nx.Serving, serving: serving, name: Assistant.Embeddings, batch_size: 32, batch_timeout: 100}
  end
end
```

Add to application.ex supervision tree (after Repo, before Oban). Batch size 32 matches Arcana's default.

#### 3. Embeddings public API

New module: `lib/assistant/embeddings.ex`

```elixir
defmodule Assistant.Embeddings do
  @moduledoc false

  @dimensions 384

  def generate(text) when is_binary(text) and byte_size(text) > 0 do
    %{embedding: tensor} = Nx.Serving.batched_run(__MODULE__, text)
    {:ok, Nx.to_flat_list(tensor)}
  end

  def generate(_), do: {:error, :empty_text}

  def generate_batch(texts) when is_list(texts) do
    results = Nx.Serving.batched_run(__MODULE__, texts)
    {:ok, Enum.map(results, fn %{embedding: t} -> Nx.to_flat_list(t) end)}
  end

  def dimensions, do: @dimensions
end
```

#### 4. Arcana embedder adapter (shares our serving)

New module: `lib/assistant/embeddings/arcana_embedder.ex`

```elixir
defmodule Assistant.Embeddings.ArcanaEmbedder do
  @moduledoc false
  @behaviour Arcana.Embedder

  @impl true
  def embed(text, _opts) do
    Assistant.Embeddings.generate(text)
  end

  @impl true
  def dimensions(_opts), do: 384

  @impl true
  def embed_batch(texts, _opts) do
    Assistant.Embeddings.generate_batch(texts)
  end
end
```

Config:
```elixir
config :arcana,
  repo: Assistant.Repo,
  embedder: {Assistant.Embeddings.ArcanaEmbedder, []}
```

#### 5. Config flag

```elixir
config :assistant, :embeddings, enabled: true
config :assistant, :embeddings, enabled: false  # test.exs
```

---

### Phase 3b: Semantic Chunker

**Goal**: Implement embedding-based topic boundary detection as an `Arcana.Chunker`.

#### The algorithm

```
Input: "The quick brown fox... Machine learning is a subset of AI..."

Step 1: Split into sentences
  → ["The quick brown fox...", "It jumped over...", "Machine learning is...", "Neural networks..."]

Step 2: Batch-embed all sentences (one call, ~30ms for a page)
  → [vec_0, vec_1, vec_2, vec_3]

Step 3: Compute cosine similarity between adjacent pairs
  → [cos(0,1)=0.92, cos(1,2)=0.31, cos(2,3)=0.89]

Step 4: Detect boundaries where similarity < threshold (default 0.5)
  → Boundary between sentence 1 and 2

Step 5: Group sentences between boundaries into chunks
  → Chunk 1: "The quick brown fox... It jumped over..."
  → Chunk 2: "Machine learning is... Neural networks..."

Step 6: If any chunk > 512 tokens, split at the next-lowest similarity point within it
Step 7: If any chunk < min_size (50 tokens), merge with neighbor that has higher similarity
```

#### Implementation

New module: `lib/assistant/embeddings/semantic_chunker.ex`

```elixir
defmodule Assistant.Embeddings.SemanticChunker do
  @moduledoc false
  @behaviour Arcana.Chunker

  @similarity_threshold 0.5
  @max_tokens 450           # leave headroom below gte-small's 512 limit
  @min_tokens 50
  @approx_chars_per_token 4

  @impl true
  def chunk(text, opts \\ []) do
    threshold = Keyword.get(opts, :similarity_threshold, @similarity_threshold)

    text
    |> split_sentences()
    |> embed_sentences()
    |> compute_similarities()
    |> detect_boundaries(threshold)
    |> group_into_chunks()
    |> enforce_size_limits()
    |> add_metadata(text)
  end

  # Split on sentence boundaries (period + space, newlines, markdown headers)
  defp split_sentences(text) do
    # First split on markdown headers (these are always boundaries)
    # Then split remaining blocks on sentence-ending punctuation
    text
    |> String.split(~r/(?=^#{1,6}\s)/m)
    |> Enum.flat_map(&split_block_sentences/1)
    |> Enum.reject(&(String.trim(&1) == ""))
  end

  defp split_block_sentences(block) do
    # Split on sentence boundaries: ". ", "! ", "? ", or double newline
    String.split(block, ~r/(?<=[.!?])\s+|\n\n+/)
  end

  defp embed_sentences(sentences) do
    {:ok, embeddings} = Assistant.Embeddings.generate_batch(sentences)
    Enum.zip(sentences, embeddings)
  end

  defp compute_similarities(sentence_embeddings) do
    sentence_embeddings
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.map(fn [{_s1, e1}, {_s2, e2}] -> cosine_similarity(e1, e2) end)
  end

  defp cosine_similarity(a, b) do
    # Vectors are already L2-normalized by gte-small, so dot product = cosine
    Enum.zip_reduce(a, b, 0.0, fn x, y, acc -> acc + x * y end)
  end

  defp detect_boundaries(similarities, threshold) do
    similarities
    |> Enum.with_index()
    |> Enum.filter(fn {sim, _idx} -> sim < threshold end)
    |> Enum.map(fn {_sim, idx} -> idx + 1 end)  # boundary AFTER this index
  end

  defp group_into_chunks(sentences, boundaries) do
    # Split sentence list at boundary indices
    # Returns list of sentence groups
  end

  defp enforce_size_limits(chunks) do
    # If chunk > @max_tokens chars, sub-split at lowest internal similarity
    # If chunk < @min_tokens chars, merge with most-similar neighbor
  end

  defp add_metadata(chunks, original_text) do
    # Add chunk_index, byte_start, byte_end, token_count estimate
    chunks
    |> Enum.with_index()
    |> Enum.map(fn {text, idx} ->
      %{
        text: text,
        chunk_index: idx,
        token_count: div(byte_size(text), @approx_chars_per_token)
      }
    end)
  end
end
```

Config:
```elixir
config :arcana, chunker: {Assistant.Embeddings.SemanticChunker, similarity_threshold: 0.5}
```

#### Markdown-aware enhancement

For documents that came from the sync pipeline (all markdown):
1. **Preserve header context**: Each chunk gets a `header_path` metadata field (e.g., `"## Setup > ### Prerequisites"`)
2. **Headers are always boundaries**: Never split a section mid-header
3. **Header text prepended to chunk**: So the embedding captures section context

```elixir
# In metadata
%{
  text: "### Prerequisites\nYou need Elixir 1.17...",
  chunk_index: 3,
  token_count: 120,
  header_path: "Setup > Prerequisites",  # breadcrumb trail
  source_type: :markdown
}
```

---

### Phase 3c: Memory embeddings + activation model

**Goal**: Embed memory entries, implement a GNN-inspired scoring model that combines semantic similarity, recency decay, access reinforcement, and spreading activation — all in SQL, no graph infrastructure.

#### The model: Spreading Activation via Embedding Space

A GNN propagates activation through graph edges. We use **cosine similarity as implicit edges** — the embedding space IS the graph. No adjacency matrix, no message-passing framework, just math.

```
                    ┌─────────────┐
                    │   Query     │
                    │  embedding  │
                    └──────┬──────┘
                           │ cosine similarity (implicit edges)
              ┌────────────┼────────────────┐
              ▼            ▼                 ▼
         ┌────────┐  ┌────────┐        ┌────────┐
         │ Mem A  │  │ Mem B  │        │ Mem C  │
         │ sim=.9 │  │ sim=.7 │  ...   │ sim=.3 │
         │ fresh  │  │ stale  │        │ fresh  │
         │ 12 hits│  │ 1 hit  │        │ 40 hits│
         └────┬───┘  └────────┘        └────────┘
              │ spreading activation
              ▼ (top-K retrieval boosts neighbors)
         ┌────────┐
         │ Mem D  │  ← semantically near A, gets decay refreshed
         │ sim=.4 │    even though it wasn't directly retrieved
         └────────┘
```

#### Scoring formula (single SQL query)

```sql
score(memory, query) =
    0.35 × semantic_sim                    -- cosine similarity (GNN "message")
  + 0.20 × fts_rank                       -- lexical match
  + 0.15 × importance                     -- user-set node weight
  + 0.15 × recency_decay                  -- Ebbinghaus forgetting curve
  + 0.15 × activation_strength            -- reinforcement (access frequency)
```

**Recency decay** (Ebbinghaus forgetting curve):
```sql
recency_decay = EXP(-0.01 × EXTRACT(EPOCH FROM (now() - accessed_at)) / 3600)
-- λ=0.01 → half-life ≈ 69 hours (~3 days)
-- Recently accessed = ~1.0, 1 week stale = ~0.19, 1 month = ~0.001
```

**Activation strength** (synaptic reinforcement with diminishing returns):
```sql
activation_strength = LN(access_count + 1) / LN(max_access_count + 1)
-- 1 hit = 0.0, 10 hits = ~0.6, 100 hits = ~0.85, 1000 hits = ~0.95
-- Logarithmic: early hits matter most, like real synaptic strengthening
```

**decay_factor** (spreading activation multiplier):
```sql
-- decay_factor starts at 1.0, gets boosted by spreading activation
-- Applied as a multiplier on the final score
final_score = score × decay_factor
```

#### 1. Migration: add embedding + access_count

```elixir
alter table(:memory_entries) do
  add :embedding, :vector, size: 384
  add :access_count, :integer, default: 0, null: false
end

create index(:memory_entries, [:embedding],
  using: "hnsw",
  options: "WITH (m = 16, ef_construction = 64)",
  where: "embedding IS NOT NULL"
)
```

Update schema: add `:embedding`, `:access_count` fields.

#### 2. Embed on memory creation (async)

New Oban worker: `lib/assistant/embeddings/embed_memory_worker.ex`
- Queue: `:embeddings` (concurrency 3)
- Reads entry content, calls `Embeddings.generate/1`, updates row

Hook into `Memory.Store.create_memory_entry/1` — after insert, enqueue job.

#### 3. Update `touch_accessed_at` to also increment access_count

In `Memory.Store`:
```elixir
def touch_access(entry_ids) do
  from(me in MemoryEntry, where: me.id in ^entry_ids)
  |> Repo.update_all(set: [accessed_at: DateTime.utc_now()],
                     inc: [access_count: 1])
end
```

#### 4. Hybrid search with full activation model

New function in `Memory.Search`:

```elixir
def hybrid_search(user_id, query_text, opts \\ []) do
  limit = Keyword.get(opts, :limit, 10)
  {:ok, query_embedding} = Embeddings.generate(query_text)

  # Subquery to get max access_count for normalization
  max_access_q = from(me in MemoryEntry,
    where: me.user_id == ^user_id,
    select: max(me.access_count)
  )

  from(me in MemoryEntry,
    where: me.user_id == ^user_id,
    inner_lateral_join: stats in subquery(max_access_q), on: true,
    select: %{
      entry: me,
      score: fragment("""
        (
          -- Semantic similarity (0-1): cosine sim via pgvector
          (CASE WHEN ? IS NOT NULL AND embedding IS NOT NULL THEN
            (1.0 - (embedding <=> ?::vector)) ELSE 0 END) * 0.35

          -- FTS relevance (0-1): normalized ts_rank
          + (CASE WHEN search_text @@ plainto_tsquery('english', ?) THEN
            ts_rank(search_text, plainto_tsquery('english', ?)) ELSE 0 END) * 0.20

          -- Importance (0-1): user-set weight
          + COALESCE(importance, 0.5) * 0.15

          -- Recency decay (0-1): Ebbinghaus curve, half-life ~3 days
          + EXP(-0.01 * EXTRACT(EPOCH FROM (NOW() - COALESCE(accessed_at, inserted_at))) / 3600) * 0.15

          -- Activation strength (0-1): log-dampened access frequency
          + (CASE WHEN ? > 0 THEN
            LN(access_count + 1) / LN(? + 1) ELSE 0 END) * 0.15
        )
        -- Spreading activation multiplier (boosted by neighbor retrieval)
        * COALESCE(decay_factor, 1.0)
      """,
        ^query_embedding, ^query_embedding,
        ^query_text, ^query_text,
        stats.max, stats.max
      )
    },
    order_by: [desc: fragment("score")],
    limit: ^limit
  )
  |> Repo.all()
  |> tap(&touch_access(Enum.map(&1, fn %{entry: e} -> e.id end)))
  |> tap(&spread_activation(user_id, &1))
end
```

#### 5. Spreading activation (the GNN message-passing step)

After retrieval, boost semantically nearby memories — this is the key insight that makes it GNN-like without a graph:

New module: `lib/assistant/memory/activation.ex`

```elixir
defmodule Assistant.Memory.Activation do
  @moduledoc false

  @spread_rate 0.05      # how much activation spreads per retrieval
  @neighbor_count 5       # top-K neighbors to activate
  @min_similarity 0.6     # only spread to sufficiently similar memories
  @max_decay_factor 1.5   # cap so it doesn't grow unbounded

  def spread(user_id, retrieved_entries) do
    retrieved_ids = Enum.map(retrieved_entries, & &1.id)
    retrieved_embeddings = Enum.map(retrieved_entries, & &1.embedding)

    # For each retrieved memory, find top-K nearest neighbors NOT in retrieved set
    # and bump their decay_factor
    Enum.each(retrieved_embeddings, fn embedding ->
      from(me in MemoryEntry,
        where: me.user_id == ^user_id
          and me.id not in ^retrieved_ids
          and not is_nil(me.embedding)
          and fragment("1 - (embedding <=> ?::vector)", ^embedding) > ^@min_similarity,
        order_by: fragment("embedding <=> ?::vector", ^embedding),
        limit: ^@neighbor_count
      )
      |> Repo.update_all(
        set: [
          decay_factor: fragment(
            "LEAST(?, COALESCE(decay_factor, 1.0) + ? * (1 - (embedding <=> ?::vector)))",
            ^@max_decay_factor, ^@spread_rate, ^embedding
          )
        ]
      )
    end)
  end
end
```

What this does:
- When you ask about "Elixir GenServers", that memory gets retrieved
- Its 5 nearest neighbors ("OTP supervision", "process linking", "Registry patterns") get their `decay_factor` bumped proportional to similarity
- Next time you search for something adjacent, those neighbors score higher
- `decay_factor` is capped at 1.5 to prevent runaway amplification
- Over time, unused `decay_factor` decays back toward 1.0 via a cron job

#### 6. Decay factor cooling (prevents stale amplification)

Oban cron worker: `lib/assistant/memory/decay_cooling_worker.ex`
- Runs daily (or hourly for more granularity)
- Gradually moves all `decay_factor` values back toward 1.0:

```elixir
# Cool 10% toward 1.0 each day
from(me in MemoryEntry,
  where: me.decay_factor != 1.0
)
|> Repo.update_all(
  set: [decay_factor: fragment("1.0 + (decay_factor - 1.0) * 0.9")]
)
```

A memory boosted to 1.3 today → 1.27 tomorrow → 1.24 next day → asymptotically back to 1.0 unless re-activated.

#### 7. Backfill existing entries

Mix task `mix assistant.backfill_embeddings`:
- Batches of 32, queries WHERE embedding IS NULL
- Generates + updates, logs progress
- Sets `access_count = 0` for entries without it

---

### Phase 3d: Document ingestion + folder activation model

**Goal**: Chunk synced documents with the semantic chunker, embed + store via Arcana, and implement folder-based spreading activation for documents.

#### The folder-as-graph model

Folders are implicit graph structure — documents in the same folder are "associated" like memories near each other in embedding space. We treat folders as nodes and folder membership as edges.

```
                    ┌─────────────────────────────────┐
                    │  Folder: "Project Alpha"         │
                    │  embedding = mean(child embeddings)│
                    │  activation_boost = 1.0           │
                    │                                   │
                    │  ┌─────────┐  ┌──────────────┐   │
                    │  │ req.md  │  │ arch.md      │   │
                    │  │ 8 chunks│  │ 12 chunks    │   │
  query hits ──────►│  │ ★ hit   │  │ gets boost   │   │
  chunk from req.md │  └─────────┘  └──────────────┘   │
                    │  ┌─────────┐  ┌──────────────┐   │
                    │  │ api.json│  │ notes.md     │   │
                    │  │ 4 chunks│  │ 6 chunks     │   │
                    │  │gets boost│  │ gets boost   │   │
                    │  └─────────┘  └──────────────┘   │
                    └─────────────────────────────────┘

  Folder: "Onboarding"  ← NOT boosted (different folder)
    ├── setup.md
    └── faq.md
```

**Three levels of association (non-recursive):**

| Level | Association | Mechanism |
|-------|-------------|-----------|
| Chunk ↔ Chunk (same doc) | Arcana handles natively | Same `document_id` in arcana_chunks |
| Doc ↔ Doc (same folder) | **NEW**: sibling activation | Retrieve chunk → boost sibling docs' `activation_boost` |
| Folder ↔ Query (folder as node) | **NEW**: folder embeddings | Folder embedding = mean of child doc embeddings, searchable |

#### 1. Migration: persist folder info + add document activation fields

Currently `synced_files` has NO folder reference (parent folder is transient from Drive API). We need to persist it, plus add a folder nodes table.

```elixir
# Migration 1: Add parent_folder_id to synced_files
alter table(:synced_files) do
  add :parent_folder_id, :string    # Google Drive folder ID
  add :parent_folder_name, :string  # Human-readable folder name
end

create index(:synced_files, [:parent_folder_id])
create index(:synced_files, [:user_id, :parent_folder_id])

# Migration 2: Document folders table (folder nodes)
create table(:document_folders, primary_key: false) do
  add :id, :binary_id, primary_key: true
  add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
  add :drive_folder_id, :string, null: false    # Google Drive folder ID
  add :drive_id, :string                         # shared drive ID or nil
  add :name, :string, null: false
  add :embedding, :vector, size: 384             # mean of child doc embeddings
  add :activation_boost, :float, default: 1.0    # spreading activation multiplier
  add :child_count, :integer, default: 0
  timestamps(type: :utc_datetime_usec)
end

create unique_index(:document_folders, [:user_id, :drive_folder_id])
create index(:document_folders, [:embedding],
  using: "hnsw",
  options: "WITH (m = 16, ef_construction = 64)",
  where: "embedding IS NOT NULL"
)
```

Schema: `lib/assistant/schemas/document_folder.ex`

#### 2. Persist parent folder during sync

In `FileSyncWorker` — the Drive Changes API already returns `parents` for each file. Currently discarded after scope check. Now persist it:

```elixir
# In file_sync_worker.ex, after successful sync:
Repo.update(synced_file,
  parent_folder_id: change.parents |> List.first(),
  parent_folder_name: resolve_folder_name(change.parents |> List.first())
)
```

Also upsert the `document_folders` entry:
```elixir
DocumentFolder.upsert(%{
  user_id: user_id,
  drive_folder_id: parent_folder_id,
  drive_id: drive_id,
  name: folder_name
})
```

#### 3. Arcana ingestion (same as before, plus folder metadata)

```elixir
Arcana.ingest(content,
  collection: "user_documents",
  source_id: synced_file.drive_file_id,
  metadata: %{
    user_id: synced_file.user_id,
    file_name: synced_file.drive_file_name,
    mime_type: synced_file.drive_mime_type,
    drive_id: synced_file.drive_id,
    parent_folder_id: synced_file.parent_folder_id,    # NEW
    parent_folder_name: synced_file.parent_folder_name  # NEW
  }
)
```

On re-sync: delete old Arcana document by `source_id`, re-ingest.

#### 4. Folder embedding (aggregate of child docs)

After any document in a folder is ingested/re-ingested, recompute the folder's embedding as the **mean of its children's document-level embeddings**:

New module: `lib/assistant/embeddings/folder_embedder.ex`

```elixir
defmodule Assistant.Embeddings.FolderEmbedder do
  @moduledoc false

  def recompute(user_id, drive_folder_id) do
    # Get all chunks for documents in this folder, average their embeddings
    child_embeddings =
      from(ac in "arcana_chunks",
        join: ad in "arcana_documents", on: ac.document_id == ad.id,
        where: fragment("?->>'parent_folder_id' = ?", ad.metadata, ^drive_folder_id)
          and fragment("?->>'user_id' = ?", ad.metadata, ^to_string(user_id))
          and not is_nil(ac.embedding),
        select: ac.embedding
      )
      |> Repo.all()

    case child_embeddings do
      [] -> :noop
      embeddings ->
        # Mean pooling: average all chunk embeddings
        folder_embedding = mean_embedding(embeddings)

        from(df in DocumentFolder,
          where: df.user_id == ^user_id and df.drive_folder_id == ^drive_folder_id
        )
        |> Repo.update_all(set: [
          embedding: folder_embedding,
          child_count: length(embeddings)
        ])
    end
  end

  defp mean_embedding(embeddings) do
    n = length(embeddings)
    embeddings
    |> Enum.zip_with(fn vals -> Enum.sum(vals) / n end)
  end
end
```

This runs after `EmbedDocumentWorker` completes, as a follow-up step.

#### 5. Document spreading activation (folder-scoped)

New module: `lib/assistant/embeddings/document_activation.ex`

```elixir
defmodule Assistant.Embeddings.DocumentActivation do
  @moduledoc false

  @spread_rate 0.03
  @max_boost 1.3

  @doc """
  When chunks from a document are retrieved, boost sibling documents
  in the same folder. Non-recursive — only direct folder siblings.
  """
  def spread(retrieved_chunks) do
    # Group retrieved chunks by parent_folder_id
    retrieved_chunks
    |> Enum.group_by(fn chunk -> chunk.metadata["parent_folder_id"] end)
    |> Enum.each(fn {nil, _} -> :skip  # no folder = no spreading
                     {folder_id, chunks} -> spread_in_folder(folder_id, chunks)
    end)
  end

  defp spread_in_folder(folder_id, retrieved_chunks) do
    retrieved_doc_ids = retrieved_chunks |> Enum.map(& &1.document_id) |> Enum.uniq()

    # Boost sibling documents in the same folder (via Arcana metadata)
    # We update the folder's activation_boost
    from(df in DocumentFolder,
      where: df.drive_folder_id == ^folder_id
    )
    |> Repo.update_all(set: [
      activation_boost: fragment(
        "LEAST(?, COALESCE(activation_boost, 1.0) + ?)",
        ^@max_boost, ^(@spread_rate * length(retrieved_chunks))
      )
    ])
  end
end
```

#### 6. Folder-aware document search

Enhanced Arcana search that factors in folder activation:

```elixir
def search_documents(user_id, query_text, opts \\ []) do
  limit = Keyword.get(opts, :limit, 10)

  # Step 1: Arcana semantic + FTS search
  arcana_results = Arcana.search(query_text,
    collection: "user_documents",
    mode: :hybrid,
    semantic_weight: 0.7,
    fulltext_weight: 0.3,
    limit: limit * 2,  # overfetch for re-ranking
    where: [metadata: %{user_id: to_string(user_id)}]
  )

  # Step 2: Load folder activation boosts
  folder_ids = arcana_results
    |> Enum.map(fn r -> r.metadata["parent_folder_id"] end)
    |> Enum.uniq()
    |> Enum.reject(&is_nil/1)

  folder_boosts = from(df in DocumentFolder,
    where: df.drive_folder_id in ^folder_ids,
    select: {df.drive_folder_id, df.activation_boost}
  ) |> Repo.all() |> Map.new()

  # Step 3: Re-rank with folder boost
  arcana_results
  |> Enum.map(fn result ->
    folder_id = result.metadata["parent_folder_id"]
    boost = Map.get(folder_boosts, folder_id, 1.0)
    %{result | score: result.score * boost}
  end)
  |> Enum.sort_by(& &1.score, :desc)
  |> Enum.take(limit)
  |> tap(&DocumentActivation.spread/1)  # spreading activation post-retrieval
end

  # Step 4 (bonus): Also search folder embeddings for topic-level matches
  def search_folders(user_id, query_text, opts \\ []) do
    limit = Keyword.get(opts, :limit, 3)
    {:ok, query_embedding} = Embeddings.generate(query_text)

    from(df in DocumentFolder,
      where: df.user_id == ^user_id and not is_nil(df.embedding),
      order_by: fragment("embedding <=> ?::vector", ^query_embedding),
      limit: ^limit,
      select: %{
        folder: df,
        similarity: fragment("1 - (embedding <=> ?::vector)", ^query_embedding)
      }
    )
    |> Repo.all()
  end
```

#### 7. Folder activation cooling

Add to the existing `DecayCoolingWorker` cron:

```elixir
# Cool folder boosts 10% toward 1.0 each day
from(df in DocumentFolder,
  where: df.activation_boost != 1.0
)
|> Repo.update_all(
  set: [activation_boost: fragment("1.0 + (activation_boost - 1.0) * 0.9")]
)
```

#### 8. Document search via Arcana (direct, no folder boost)

For cases where you just want raw Arcana search without folder re-ranking:

```elixir
Arcana.search(query,
  collection: "user_documents",
  mode: :hybrid,
  semantic_weight: 0.7,
  fulltext_weight: 0.3,
  limit: 10,
  where: [metadata: %{user_id: user_id}]
)
```

---

### Phase 3e: Unified search + skill wiring

**Goal**: Combine memory and document search, wire into context builder and skills.

#### 1. Unified search module

New module: `lib/assistant/embeddings/unified_search.ex`

```elixir
defmodule Assistant.Embeddings.UnifiedSearch do
  @moduledoc false

  def search(user_id, query, opts \\ []) do
    limit = Keyword.get(opts, :limit, 10)

    # Fan out in parallel
    memory_task = Task.async(fn ->
      Memory.Search.hybrid_search(user_id, query, limit: limit)
    end)

    doc_task = Task.async(fn ->
      Arcana.search(query,
        collection: "user_documents",
        mode: :hybrid,
        limit: limit,
        where: [metadata: %{user_id: user_id}]
      )
    end)

    memories = Task.await(memory_task, 5_000)
    docs = Task.await(doc_task, 5_000)

    # Normalize scores to 0-1, interleave via RRF, return top N
    merge_rrf(memories, docs, limit)
  end
end
```

#### 2. Context builder upgrade

In `Memory.ContextBuilder`:
- If embeddings enabled: call `UnifiedSearch.search/3` with the current user message
- Inject top-K results as context (memories + relevant doc chunks with header breadcrumbs)
- Fall back to existing FTS-only path if disabled

#### 3. Skill updates

**Skills.Files.Search** — add semantic mode:
- Default behavior: query `Arcana.search` against `user_documents` collection
- Returns file name, chunk excerpt, header path, similarity score

**Skills.Memory.Search** — add semantic mode:
- Use `hybrid_search` (combined FTS + vector + importance)
- Display similarity score in results

---

## Arcana's Agentic Pipeline (Future Enhancement)

Arcana includes an `Agent` pipeline with steps we could wire in later:

| Step | Value for us |
|------|-------------|
| `gate/2` | Skip retrieval for simple greetings/commands |
| `rewrite/2` | Clean conversational queries into search queries |
| `expand/2` | Add synonyms to improve recall |
| `rerank/2` | LLM-based re-scoring of retrieved chunks |
| `reason/2` | Multi-hop: search → read → search again |

These are optional enhancements. The core pipeline (chunk → embed → search) works without them.

---

## Testing Strategy

- **SemanticChunker tests**: Verify boundary detection with known topic-shift texts, edge cases (single sentence, very long section, empty input)
- **ArcanaEmbedder tests**: Mock `Nx.Serving.batched_run/2`, verify delegation
- **Memory activation tests**: Verify 5-signal scoring, spreading activation boost/cap/cooling, access_count increment
- **Document activation tests**: Verify folder boost applied to search results, folder embedding recompute, sibling activation
- **Folder embedder tests**: Verify mean pooling of child doc embeddings, recompute on doc change
- **Memory hybrid search tests**: Mock embeddings, verify spreading activation fires post-retrieval
- **Arcana ingest/search tests**: Use test collection, verify end-to-end with mock embedder
- **Config toggle**: All embedding tests skip when `embeddings.enabled == false`

```elixir
# test.exs
config :assistant, :embeddings, enabled: false
config :arcana, embedder: {Assistant.Embeddings.MockEmbedder, dimensions: 384}
```

---

## Performance

| Operation | Latency | Notes |
|-----------|---------|-------|
| Sentence embedding batch (32) | ~50ms | One Nx.Serving call for chunker |
| Semantic chunk a 10-page doc | ~200ms | ~200 sentences, 7 batches |
| pgvector HNSW search (10K) | <5ms | Cosine distance |
| Arcana hybrid search | ~20ms | Single CTE query (FTS + vector) |
| Memory hybrid search (5-signal) | ~30ms | FTS + vector + importance + recency + activation |
| Memory spreading activation | ~15ms | 5 neighbor lookups × pgvector scan |
| Folder-aware doc search | ~25ms | Arcana search + folder boost lookup |
| Document spreading activation | ~5ms | Single UPDATE on folder activation_boost |
| Folder embedding recompute | ~10ms | Mean of child embeddings (post-ingest) |
| Unified search (parallel) | ~35ms | Max of memory + doc, not sum |
| Cooling cron (memories + folders) | <100ms | Two UPDATEs on != 1.0 rows |

Model memory: ~70MB for gte-small. Single serving shared by all consumers.

---

## The Dual Activation Model at a Glance

### Memory Activation (embedding-space graph)

```
  Query: "How do GenServers work?"
                    │
    ┌───────────────┴───────────────┐
    │     5-Signal Scoring          │
    │                               │
    │  35% semantic similarity      │  ← cosine sim (implicit edges)
    │  20% FTS rank                 │  ← lexical match
    │  15% importance               │  ← user-set node weight
    │  15% recency decay            │  ← Ebbinghaus curve (e^-λt)
    │  15% activation strength      │  ← ln(hits+1) reinforcement
    │       × decay_factor          │  ← spreading activation multiplier
    └───────────────┬───────────────┘
                    │
    ┌───────────────┴───────────────┐
    │  Post-Retrieval Spreading     │
    │                               │
    │  For each retrieved memory:   │
    │    → 5 nearest neighbors      │
    │    → Bump their decay_factor  │
    │    → Cap at 1.5               │
    └───────────────────────────────┘
```

### Document Activation (folder-structure graph)

```
  Query: "API authentication flow"
                    │
    ┌───────────────┴───────────────┐
    │  Arcana Hybrid Search         │
    │  (semantic + FTS)             │
    │       × folder activation_boost│  ← folder-level multiplier
    └───────────────┬───────────────┘
                    │
    ┌───────────────┴───────────────┐
    │  Retrieved: chunk from        │
    │  "Project Alpha/api-spec.json"│
    └───────────────┬───────────────┘
                    │
    ┌───────────────┴───────────────┐
    │  Folder Spreading             │
    │  (non-recursive)              │
    │                               │
    │  "Project Alpha" folder:      │
    │    activation_boost 1.0→1.03  │
    │                               │
    │  Next search: ALL docs in     │
    │  "Project Alpha" score higher │
    │  (arch.md, req.md, notes.md)  │
    └───────────────────────────────┘
                    │
    ┌───────────────┴───────────────┐
    │  Folder as Searchable Node    │
    │                               │
    │  "Project Alpha" folder has   │
    │  its own embedding (mean of   │
    │  child doc embeddings).       │
    │                               │
    │  search_folders("auth") →     │
    │  "Project Alpha" (sim=0.82)   │
    │  → surfaces whole folder as   │
    │    relevant topic cluster     │
    └───────────────────────────────┘
```

### GNN analogy (both systems)

| GNN Concept | Memory System | Document System |
|-------------|---------------|-----------------|
| **Nodes** | Memory entries | Documents + Folders |
| **Edges** | Cosine similarity (implicit) | Folder membership (explicit) + cosine similarity |
| **Node features** | importance, access_count, recency | content embedding, file metadata |
| **Message passing** | Spreading activation via embedding neighbors | Folder activation boost on sibling retrieval |
| **Aggregation** | — | Folder embedding = mean(child embeddings) |
| **Temporal dynamics** | Ebbinghaus decay + cooling cron | Folder activation cooling cron |

No graph DB, no adjacency matrix, no PyTorch Geometric. Just SQL + pgvector + folder structure.

---

## Migration Path

1. **3a** — Foundation: deps, pgvector, serving, Arcana install. Zero behavior change.
2. **3b** — Semantic chunker: custom `Arcana.Chunker` with boundary detection.
3. **3c** — Memory embeddings + activation: embedding column, access_count, 5-signal hybrid search, spreading activation, decay cooling cron.
4. **3d** — Document ingestion + folder activation: persist parent_folder_id, document_folders table, Arcana pipeline, folder embeddings, folder-scoped spreading activation.
5. **3e** — Unified search + skills: context builder, file search, memory search, folder search.

Each phase independently deployable. FTS continues working throughout.

---

## File Inventory

### New files
- `lib/assistant/embeddings.ex` — public API (generate, generate_batch)
- `lib/assistant/embeddings/serving.ex` — shared Bumblebee Nx.Serving
- `lib/assistant/embeddings/arcana_embedder.ex` — Arcana.Embedder adapter
- `lib/assistant/embeddings/semantic_chunker.ex` — Arcana.Chunker with boundary detection
- `lib/assistant/embeddings/embed_memory_worker.ex` — Oban worker for memories
- `lib/assistant/embeddings/embed_document_worker.ex` — Oban worker for doc ingestion + folder embedding recompute
- `lib/assistant/embeddings/folder_embedder.ex` — mean-pool child embeddings into folder node
- `lib/assistant/embeddings/document_activation.ex` — folder-scoped spreading activation for documents
- `lib/assistant/embeddings/unified_search.ex` — cross-source search (memories + docs + folders)
- `lib/assistant/memory/activation.ex` — embedding-space spreading activation for memories
- `lib/assistant/memory/decay_cooling_worker.ex` — Oban cron for memory decay_factor + folder activation_boost cooldown
- `lib/assistant/schemas/document_folder.ex` — Ecto schema for folder nodes
- Migration: enable pgvector + add embedding + access_count to memory_entries
- Migration: add parent_folder_id/name to synced_files
- Migration: create document_folders table
- Arcana-generated migrations (collections, documents, chunks)
- Test files for each module

### Modified files
- `mix.exs` — add `arcana`, `exla`
- `lib/assistant/application.ex` — add Embeddings.Serving to supervision tree
- `config/config.exs` — embeddings + arcana config
- `config/test.exs` — disable embeddings, mock embedder
- `lib/assistant/memory/search.ex` — add hybrid_search with 5-signal scoring
- `lib/assistant/memory/store.ex` — enqueue embed job after create, update touch_access to inc access_count
- `lib/assistant/memory/context_builder.ex` — use unified search
- `lib/assistant/sync/workers/file_sync_worker.ex` — persist parent_folder_id, enqueue doc ingestion
- `lib/assistant/skills/files/search.ex` — semantic search mode with folder boost
- `lib/assistant/skills/memory/search.ex` — hybrid search mode
- `lib/assistant/schemas/memory_entry.ex` — add :embedding, :access_count fields
- `lib/assistant/schemas/synced_file.ex` — add :parent_folder_id, :parent_folder_name fields
