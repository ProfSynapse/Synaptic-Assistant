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

### Phase 3c: Memory entry embeddings

**Goal**: Embed memory entries directly (no chunking — they're already atomic). Add hybrid search.

#### 1. Add embedding column to memory_entries

Migration:
```elixir
alter table(:memory_entries) do
  add :embedding, :vector, size: 384
end

create index(:memory_entries, [:embedding],
  using: "hnsw",
  options: "WITH (m = 16, ef_construction = 64)",
  where: "embedding IS NOT NULL"
)
```

#### 2. Embed on memory creation (async)

New Oban worker: `lib/assistant/embeddings/embed_memory_worker.ex`
- Queue: `:embeddings` (concurrency 3)
- Reads entry content, calls `Embeddings.generate/1`, updates row

Hook into `Memory.Store.create_memory_entry/1` — after insert, enqueue job.

#### 3. Hybrid search on memories

New function in `Memory.Search`:

```elixir
def hybrid_search(user_id, query_text, opts \\ []) do
  limit = Keyword.get(opts, :limit, 10)
  {:ok, query_embedding} = Embeddings.generate(query_text)

  # Single SQL query: FTS score + vector score + importance, combined
  from(me in MemoryEntry,
    where: me.user_id == ^user_id,
    select: %{
      entry: me,
      score: fragment("""
        (CASE WHEN search_text @@ plainto_tsquery('english', ?) THEN
          ts_rank(search_text, plainto_tsquery('english', ?)) ELSE 0 END) * 0.3
        + (CASE WHEN embedding IS NOT NULL THEN
          (1 - (embedding <=> ?::vector)) ELSE 0 END) * 0.5
        + (importance / 10.0) * 0.2
      """, ^query_text, ^query_text, ^query_embedding)
    },
    order_by: [desc: fragment("score")],
    limit: ^limit
  )
  |> Repo.all()
end
```

Weights: 50% semantic, 30% FTS, 20% importance. Tunable.

#### 4. Backfill existing entries

Mix task `mix assistant.backfill_embeddings`:
- Batches of 32, queries WHERE embedding IS NULL
- Generates + updates, logs progress

---

### Phase 3d: Document ingestion via Arcana

**Goal**: Chunk synced documents with the semantic chunker, embed + store via Arcana.

#### 1. Create a default Arcana collection

On app startup or first use:
```elixir
Arcana.create_collection("user_documents", description: "Synced user documents")
```

#### 2. Hook into FileSyncWorker

After successful file sync:
1. Check if content is text-based (md, csv, txt, json — the sync pipeline already converts Google Docs/Sheets/Slides to these)
2. Enqueue `EmbedDocumentWorker` Oban job
3. Worker calls:

```elixir
Arcana.ingest(content,
  collection: "user_documents",
  source_id: synced_file.drive_file_id,
  metadata: %{
    user_id: synced_file.user_id,
    file_name: synced_file.name,
    mime_type: synced_file.mime_type,
    drive_id: synced_file.drive_id
  }
)
```

4. On re-sync: delete old Arcana document by `source_id`, re-ingest

#### 3. Document search via Arcana

```elixir
Arcana.search(query,
  collection: "user_documents",
  mode: :hybrid,
  semantic_weight: 0.7,
  fulltext_weight: 0.3,
  limit: 10,
  where: [metadata: %{user_id: user_id}]  # scope to user
)
```

Returns chunks with text, similarity score, and document metadata (file name, path, etc.).

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
- **Memory hybrid search tests**: Mock embeddings, verify score weighting
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
| Memory hybrid search | ~25ms | FTS + vector + importance |
| Unified search (parallel) | ~30ms | Max of both, not sum |

Model memory: ~70MB for gte-small. Single serving shared by all consumers.

---

## Migration Path

1. **3a** — Foundation: deps, pgvector, serving, Arcana install. Zero behavior change.
2. **3b** — Semantic chunker: custom `Arcana.Chunker` with boundary detection.
3. **3c** — Memory embeddings: column, async embed, hybrid search, backfill.
4. **3d** — Document ingestion: Arcana pipeline, hook into file sync.
5. **3e** — Unified search + skills: context builder, file search, memory search.

Each phase independently deployable. FTS continues working throughout.

---

## File Inventory

### New files
- `lib/assistant/embeddings.ex` — public API (generate, generate_batch)
- `lib/assistant/embeddings/serving.ex` — shared Bumblebee Nx.Serving
- `lib/assistant/embeddings/arcana_embedder.ex` — Arcana.Embedder adapter
- `lib/assistant/embeddings/semantic_chunker.ex` — Arcana.Chunker with boundary detection
- `lib/assistant/embeddings/embed_memory_worker.ex` — Oban worker for memories
- `lib/assistant/embeddings/embed_document_worker.ex` — Oban worker for doc ingestion
- `lib/assistant/embeddings/unified_search.ex` — cross-source search
- Migration: enable pgvector + add embedding column to memory_entries
- Arcana-generated migrations (collections, documents, chunks)
- Test files for each module

### Modified files
- `mix.exs` — add `arcana`, `exla`
- `lib/assistant/application.ex` — add Embeddings.Serving to supervision tree
- `config/config.exs` — embeddings + arcana config
- `config/test.exs` — disable embeddings, mock embedder
- `lib/assistant/memory/search.ex` — add hybrid_search
- `lib/assistant/memory/store.ex` — enqueue embed job after create
- `lib/assistant/memory/context_builder.ex` — use unified search
- `lib/assistant/sync/workers/file_sync_worker.ex` — enqueue doc ingestion
- `lib/assistant/skills/files/search.ex` — semantic search mode
- `lib/assistant/skills/memory/search.ex` — hybrid search mode
- `lib/assistant/schemas/memory_entry.ex` — add :embedding field
