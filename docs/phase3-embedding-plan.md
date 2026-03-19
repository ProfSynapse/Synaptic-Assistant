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
- **Activation model tests**: Verify score formula weighting, spreading activation boost/cap/cooling, access_count increment
- **Memory hybrid search tests**: Mock embeddings, verify 5-signal scoring, verify spreading activation fires post-retrieval
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
| Spreading activation (post-retrieval) | ~15ms | 5 neighbor lookups × pgvector scan |
| Unified search (parallel) | ~35ms | Max of memory + doc, not sum |
| Decay cooling cron | <100ms | Single UPDATE on decay_factor != 1.0 |

Model memory: ~70MB for gte-small. Single serving shared by all consumers.

---

## The Activation Model at a Glance

```
  Query: "How do GenServers work?"
                    │
    ┌───────────────┴───────────────┐
    │     5-Signal Scoring          │
    │                               │
    │  35% semantic similarity      │  ← "GNN message" (cosine sim)
    │  20% FTS rank                 │  ← lexical match
    │  15% importance               │  ← user-set node weight
    │  15% recency decay            │  ← Ebbinghaus curve (e^-λt)
    │  15% activation strength      │  ← ln(hits+1) reinforcement
    │       × decay_factor          │  ← spreading activation multiplier
    └───────────────┬───────────────┘
                    │
    ┌───────────────┴───────────────┐
    │     Retrieved: top 10         │
    │                               │
    │  "GenServer basics"     0.92  │
    │  "handle_call patterns" 0.85  │
    │  "OTP overview"         0.71  │
    │  ...                          │
    └───────────────┬───────────────┘
                    │
    ┌───────────────┴───────────────┐
    │  Spreading Activation         │
    │  (async, post-retrieval)      │
    │                               │
    │  For each retrieved memory:   │
    │    → Find 5 nearest neighbors │
    │    → Bump their decay_factor  │
    │    → Cap at 1.5               │
    │                               │
    │  "Supervisor trees"  1.0→1.04 │
    │  "Process linking"   1.0→1.03 │
    │  "Registry patterns" 1.1→1.12 │
    └───────────────────────────────┘
                    │
    ┌───────────────┴───────────────┐
    │  Daily Cooling Cron           │
    │                               │
    │  decay_factor → 1.0 + 0.9×Δ  │
    │  (10% exponential cooldown)   │
    │  1.3 → 1.27 → 1.24 → 1.0    │
    └───────────────────────────────┘
```

This models a GNN's behavior:
- **Node features** = importance + access_count + recency
- **Edge weights** = cosine similarity in embedding space
- **Message passing** = spreading activation on retrieval
- **Temporal dynamics** = Ebbinghaus decay + cooling cron

Without any of the infrastructure: no graph DB, no adjacency matrix, no PyTorch Geometric. Just SQL + pgvector.

---

## Migration Path

1. **3a** — Foundation: deps, pgvector, serving, Arcana install. Zero behavior change.
2. **3b** — Semantic chunker: custom `Arcana.Chunker` with boundary detection.
3. **3c** — Memory embeddings + activation model: embedding column, access_count, 5-signal hybrid search, spreading activation, decay cooling cron.
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
- `lib/assistant/memory/activation.ex` — spreading activation (GNN message-passing)
- `lib/assistant/memory/decay_cooling_worker.ex` — Oban cron for decay_factor cooldown
- Migration: enable pgvector + add embedding + access_count to memory_entries
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
- `lib/assistant/sync/workers/file_sync_worker.ex` — enqueue doc ingestion
- `lib/assistant/skills/files/search.ex` — semantic search mode
- `lib/assistant/skills/memory/search.ex` — hybrid search mode
- `lib/assistant/schemas/memory_entry.ex` — add :embedding, :access_count fields
