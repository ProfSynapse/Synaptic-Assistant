# Phase 3: Local Embeddings + Semantic Search

## Overview

Add local embedding generation (Bumblebee + gte-small, 384D) and vector search (pgvector) to both memory entries and synced document chunks. Fully in-process, no external APIs, no GPU required.

## Architecture

```
                    ┌─────────────────────┐
                    │   Bumblebee Serving  │
                    │  (gte-small, 384D)   │
                    │  Nx.Serving in sup   │
                    └──────────┬──────────┘
                               │
              ┌────────────────┼────────────────┐
              ▼                ▼                 ▼
     Memory.Store      FileSyncWorker      Skills (search)
     .create_entry()   .sync_file()        .execute()
              │                │                 │
              ▼                ▼                 ▼
     ┌────────────┐   ┌──────────────┐   ┌──────────────┐
     │ memory_    │   │ document_    │   │ Hybrid       │
     │ entries    │   │ chunks       │   │ Search       │
     │ +embedding │   │ (new table)  │   │ FTS+Vec+Imp  │
     └────────────┘   └──────────────┘   └──────────────┘
              │                │                 │
              └────────────────┼─────────────────┘
                               ▼
                     PostgreSQL + pgvector
```

## Dependencies (new Hex packages)

```elixir
# mix.exs
{:bumblebee, "~> 0.6"},
{:exla, "~> 0.9"},          # XLA backend for Nx (CPU)
{:pgvector, "~> 0.3"},       # Ecto pgvector types + distance functions
{:text_chunker, "~> 0.3"},   # Recursive text chunking
```

No new external services. Everything runs in-process.

## Implementation Phases

---

### Phase 3a: Foundation (pgvector + Bumblebee serving)

**Goal**: Get the embedding infrastructure running without changing any existing behavior.

#### 1. Enable pgvector extension

Migration:
```elixir
defmodule Assistant.Repo.Migrations.EnablePgvector do
  use Ecto.Migration
  def up, do: execute("CREATE EXTENSION IF NOT EXISTS vector")
  def down, do: execute("DROP EXTENSION IF EXISTS vector")
end
```

#### 2. Add Bumblebee serving to supervision tree

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
        compile: [batch_size: 8, sequence_length: 512],
        defn_options: [compiler: EXLA]
      )

    {Nx.Serving, serving: serving, name: Assistant.Embeddings, batch_size: 8, batch_timeout: 50}
  end
end
```

Add to application.ex supervision tree (after Repo, before Oban).

#### 3. Embedding helper module

New module: `lib/assistant/embeddings.ex`

```elixir
defmodule Assistant.Embeddings do
  @moduledoc false

  @model "gte-small"
  @dimensions 384

  def generate(text) when is_binary(text) and byte_size(text) > 0 do
    %{embedding: tensor} = Nx.Serving.run(__MODULE__, text)
    {:ok, Nx.to_flat_list(tensor)}
  end

  def generate(_), do: {:error, :empty_text}

  def generate_batch(texts) when is_list(texts) do
    results = Nx.Serving.batched_run(__MODULE__, texts)
    {:ok, Enum.map(results, fn %{embedding: t} -> Nx.to_flat_list(t) end)}
  end

  def model, do: @model
  def dimensions, do: @dimensions
end
```

#### 4. Config flag for gradual rollout

```elixir
# config/config.exs
config :assistant, :embeddings,
  enabled: true,
  model: "gte-small",
  dimensions: 384,
  chunk_size: 1600,       # ~400 tokens
  chunk_overlap: 200      # ~50 tokens
```

Check `Application.get_env(:assistant, :embeddings)[:enabled]` before embedding operations. Allows disabling in test env or low-resource deploys.

---

### Phase 3b: Memory entry embeddings

**Goal**: Embed memory entries on create, add vector search to Memory.Search.

#### 1. Add embedding column to memory_entries

Migration:
```elixir
alter table(:memory_entries) do
  add :embedding, :vector, size: 384
end

create index(:memory_entries, [:embedding],
  using: "hnsw",
  options: "WITH (m = 16, ef_construction = 64)",
  comment: "HNSW index for cosine similarity search",
  where: "embedding IS NOT NULL"
)
```

Partial index (WHERE NOT NULL) so existing entries without embeddings don't bloat the index.

#### 2. Embed on memory creation

In `Memory.Store.create_memory_entry/1` — after successful insert, generate embedding async via Oban job (don't block the caller):

New worker: `lib/assistant/embeddings/embed_memory_worker.ex`
- Reads entry content
- Calls `Embeddings.generate/1`
- Updates `memory_entries.embedding` and `embedding_model`
- Oban queue: `:embeddings` (new queue, concurrency 3)

#### 3. Add vector search to Memory.Search

New function: `search_by_similarity/3`
```elixir
def search_by_similarity(user_id, query_embedding, opts \\ []) do
  limit = Keyword.get(opts, :limit, 10)

  from(me in MemoryEntry,
    where: me.user_id == ^user_id and not is_nil(me.embedding),
    order_by: fragment("embedding <=> ?::vector", ^query_embedding),
    limit: ^limit
  )
  |> Repo.all()
  |> touch_accessed_at()
  |> then(&{:ok, &1})
end
```

#### 4. Hybrid search with Reciprocal Rank Fusion

New function: `hybrid_search/3` — combines FTS + vector + importance:

```elixir
def hybrid_search(user_id, query_text, opts \\ []) do
  # 1. FTS results (existing search_memories/2)
  # 2. Vector results (embed query_text, then search_by_similarity)
  # 3. Merge via RRF: score = Σ 1/(k + rank_i), k=60
  # 4. Boost by importance score
  # 5. Return top N
end
```

RRF is simple and parameter-free (k=60 is standard). No ML needed.

#### 5. Backfill existing entries

Oban cron job or one-time Mix task: `mix assistant.backfill_embeddings`
- Queries entries WHERE embedding IS NULL, batch of 50
- Generates embeddings, updates rows
- Rate-limited to avoid overwhelming CPU on startup

---

### Phase 3c: Document chunk embeddings

**Goal**: Chunk synced documents, embed chunks, enable semantic file search.

#### 1. New `document_chunks` table

Migration:
```elixir
create table(:document_chunks, primary_key: false) do
  add :id, :binary_id, primary_key: true
  add :synced_file_id, references(:synced_files, type: :binary_id, on_delete: :delete_all), null: false
  add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
  add :chunk_index, :integer, null: false
  add :content, :text, null: false
  add :byte_start, :integer
  add :byte_end, :integer
  add :embedding, :vector, size: 384
  add :embedding_model, :string
  add :search_text, :tsvector  # trigger-populated for FTS
  add :metadata, :map, default: %{}
  timestamps(type: :utc_datetime_usec)
end

create index(:document_chunks, [:synced_file_id])
create index(:document_chunks, [:user_id])
create unique_index(:document_chunks, [:synced_file_id, :chunk_index])
create index(:document_chunks, [:embedding],
  using: "hnsw",
  options: "WITH (m = 16, ef_construction = 64)",
  where: "embedding IS NOT NULL"
)
create index(:document_chunks, [:search_text], using: "gin",
  where: "search_text IS NOT NULL")

# Trigger to populate search_text from content
execute """
CREATE TRIGGER trg_document_chunks_search_text
BEFORE INSERT OR UPDATE OF content ON document_chunks
FOR EACH ROW EXECUTE FUNCTION
  tsvector_update_trigger(search_text, 'pg_catalog.english', content)
"""
```

#### 2. Chunking module

New module: `lib/assistant/embeddings/chunker.ex`

```elixir
defmodule Assistant.Embeddings.Chunker do
  @moduledoc false

  @default_chunk_size 1600    # ~400 tokens for gte-small (512 max)
  @default_overlap 200        # ~50 tokens

  def chunk(text, opts \\ []) do
    chunk_size = Keyword.get(opts, :chunk_size, @default_chunk_size)
    overlap = Keyword.get(opts, :chunk_overlap, @default_overlap)

    # Use text_chunker for format-aware splitting
    TextChunker.split(text,
      chunk_size: chunk_size,
      chunk_overlap: overlap,
      format: detect_format(text)
    )
  end

  defp detect_format(text) do
    if String.contains?(text, ["# ", "## ", "```", "- [ ]"]),
      do: :markdown,
      else: :plaintext
  end
end
```

#### 3. Hook into FileSyncWorker

After successful file sync (content written to `synced_files`):
1. Check if file is text-based (`md`, `csv`, `txt`, `json`)
2. If so, enqueue `EmbedDocumentWorker` Oban job
3. Worker reads content, chunks it, embeds each chunk, upserts `document_chunks`
4. On re-sync: delete old chunks for that synced_file_id, re-chunk, re-embed

New worker: `lib/assistant/embeddings/embed_document_worker.ex`
- Oban queue: `:embeddings`
- Reads synced_file.content (decrypts)
- Skips binary formats (pdf images for now — text extraction deferred)
- Chunks text via `Chunker.chunk/2`
- Batch-embeds chunks via `Embeddings.generate_batch/1`
- Bulk-inserts into `document_chunks`

#### 4. Add document search

New function in `Memory.Search` or new module `Assistant.Embeddings.Search`:

```elixir
def search_documents(user_id, query_text, opts \\ []) do
  {:ok, query_embedding} = Embeddings.generate(query_text)
  limit = Keyword.get(opts, :limit, 10)

  from(dc in DocumentChunk,
    where: dc.user_id == ^user_id and not is_nil(dc.embedding),
    order_by: fragment("embedding <=> ?::vector", ^query_embedding),
    limit: ^limit,
    preload: [:synced_file]
  )
  |> Repo.all()
end
```

#### 5. Unified search across memories + documents

New module: `lib/assistant/embeddings/unified_search.ex`

```elixir
defmodule Assistant.Embeddings.UnifiedSearch do
  @moduledoc false

  def search(user_id, query, opts \\ []) do
    limit = Keyword.get(opts, :limit, 10)
    {:ok, query_embedding} = Embeddings.generate(query)

    # Fan out to both sources in parallel
    memory_task = Task.async(fn ->
      Memory.Search.hybrid_search(user_id, query, limit: limit)
    end)
    doc_task = Task.async(fn ->
      search_documents(user_id, query_embedding, limit: limit)
    end)

    memories = Task.await(memory_task)
    docs = Task.await(doc_task)

    # Merge and RRF rank
    merge_results(memories, docs, limit)
  end
end
```

---

### Phase 3d: Wire into context builder + skills

**Goal**: Make semantic search available to the orchestrator and file search skill.

#### 1. Update Memory.ContextBuilder

Replace or augment the FTS-based memory lookup with `hybrid_search/3`:
- If embeddings enabled: use `hybrid_search` (FTS + vector + importance fusion)
- If disabled: fall back to existing `search_memories/2` (FTS only)

#### 2. Update Skills.Files.Search

Add `--semantic` flag (or make it default) that queries `document_chunks` by vector similarity instead of just filename ILIKE:
- `query` param → generate embedding → search document_chunks → return file info with relevant chunk excerpts

#### 3. Update Skills.Memory.Search

Add vector search option alongside existing FTS:
- `--semantic` flag triggers `hybrid_search` instead of plain FTS
- Return similarity score alongside results

#### 4. Context-aware file injection

In `Orchestrator.ContextFiles`, optionally use semantic search to pick the most relevant synced file chunks for the current conversation topic, rather than requiring explicit file references.

---

## Testing Strategy

- **Unit tests**: Embeddings module with mock Nx.Serving (avoid loading model in CI)
- **Chunker tests**: Verify chunk sizes, overlap, byte ranges, format detection
- **Integration tests**: End-to-end memory create → embed → search with Bypass/mock
- **Migration tests**: Verify pgvector extension, HNSW index creation
- **Config toggle**: All embedding tests skip when `embeddings.enabled == false`

Test env config:
```elixir
config :assistant, :embeddings, enabled: false  # Don't load model in tests
```

For tests that need embeddings, use a tagged setup that starts a test serving or mocks `Nx.Serving.run/2`.

## Performance Considerations

| Operation | Expected Latency | Notes |
|-----------|-----------------|-------|
| Single embedding (gte-small, CPU) | 10-30ms | After JIT warmup |
| Batch of 8 embeddings | 30-80ms | Batched via Nx.Serving |
| pgvector HNSW search (10K vectors) | <5ms | Well within budget |
| pgvector HNSW search (100K vectors) | <15ms | Still fast |
| Document chunk + embed (1 page) | ~100ms | 3-4 chunks × 30ms |
| Full file re-chunk + embed | 200-500ms | Async via Oban, not blocking |

Memory overhead: gte-small model ~70MB resident. Acceptable for a Phoenix app.

## Migration Path

1. **Phase 3a** — Foundation: deps, pgvector extension, Bumblebee serving. No behavior change.
2. **Phase 3b** — Memory embeddings: embed on create, hybrid search, backfill.
3. **Phase 3c** — Document chunks: new table, chunk on sync, document search.
4. **Phase 3d** — Wire in: context builder, file search skill, memory search skill.

Each phase is independently deployable and testable. Existing FTS continues working throughout — vector search is additive, not a replacement.

## File Inventory (new/modified)

### New files
- `lib/assistant/embeddings.ex` — public API (generate, generate_batch, model, dimensions)
- `lib/assistant/embeddings/serving.ex` — Bumblebee Nx.Serving child_spec
- `lib/assistant/embeddings/chunker.ex` — text_chunker wrapper with format detection
- `lib/assistant/embeddings/embed_memory_worker.ex` — Oban worker for memory embedding
- `lib/assistant/embeddings/embed_document_worker.ex` — Oban worker for document chunking + embedding
- `lib/assistant/embeddings/unified_search.ex` — cross-source RRF search
- `lib/assistant/schemas/document_chunk.ex` — Ecto schema
- 3 migrations (pgvector extension, memory_entries embedding column, document_chunks table)
- Test files for each new module

### Modified files
- `mix.exs` — add deps (bumblebee, exla, pgvector, text_chunker)
- `lib/assistant/application.ex` — add Embeddings.Serving to supervision tree
- `config/config.exs` — embeddings config
- `config/test.exs` — disable embeddings in test
- `lib/assistant/memory/search.ex` — add search_by_similarity, hybrid_search
- `lib/assistant/memory/store.ex` — enqueue embed job after create_memory_entry
- `lib/assistant/memory/context_builder.ex` — use hybrid_search when available
- `lib/assistant/sync/workers/file_sync_worker.ex` — enqueue embed_document after sync
- `lib/assistant/skills/files/search.ex` — add semantic search option
- `lib/assistant/skills/memory/search.ex` — add semantic search option
- `lib/assistant/schemas/memory_entry.ex` — add :embedding field
