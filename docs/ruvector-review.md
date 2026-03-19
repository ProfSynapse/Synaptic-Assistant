# RuVector Review: Relevance to Synaptic-Assistant

**Date**: 2026-03-19
**Repo**: https://github.com/ruvnet/ruvector
**Reviewer**: Claude Code

## What is RuVector?

A Rust-based vector database monorepo (v2.0.6, ~120+ crates). README claims:
- HNSW vector indexing with SIMD acceleration
- Graph Neural Networks (GNNs) that adapt search rankings from usage patterns
- PostgreSQL extension (230+ SQL functions, pgvector-compatible)
- Local LLM execution (GGUF models, WASM-compatible)
- `.rvf` cognitive container format (boots in 125ms)
- MCP (Model Context Protocol) support
- Self-learning via SONA (Self-Optimizing Neural Architecture)

### Reality Check (Source Code vs README)

**Deep source code review revealed significant discrepancies:**

1. **"Self-learning GNN" is actually PageRank-weighted cosine similarity re-ranking** — not a graph neural network. No learned parameters, no training loop for search.
2. **SONA is referenced in config flags (`trigger_sona: true`) but no SONA learning code exists** in the codebase.
3. **LoRA/MicroLoRA** — config flags exist, federated weight endpoints exist, but actual adaptation logic is minimal.
4. **Default embeddings are FNV-1a character hashing, NOT semantic** — the code itself warns: "This does NOT produce semantic embeddings! 'dog' and 'cat' will NOT be similar." Real embeddings require explicit ONNX or API configuration.
5. **The "training loop"** runs every 5 minutes but primarily processes external data ingestion (NASA, NOAA, USGS feeds), not model updates.
6. **Distributed consensus is DAG-based**, not Raft as README states.

**What IS real and working:**
- Core HNSW vector index (wraps `hnsw_rs` crate) with SIMD distance calculations
- 4-tier quantization (Scalar/Int4/Product/Binary)
- Hybrid search (70% vector cosine + 30% BM25 keyword, configurable)
- Filtered search with auto pre/post-filter strategy selection
- REDB storage backend
- MCP server with 22 tools (brain_search, brain_share, etc.)
- Web ingestion pipeline with chunking (~2048 chars, 256 overlap)
- ONNX embedding support (all-MiniLM-L6-v2, 384D) when feature-gated

**Repo age**: ~4 months (Nov 2025). 120+ crates spanning vector DB, quantum error correction, robotics middleware, financial trading, CNN image processing — breadth suggests bundled projects, not a unified system.

## Current Synaptic-Assistant Memory Architecture

Our memory system uses:
- **PostgreSQL full-text search** (`tsvector`/`plainto_tsquery`) via `Memory.Search`
- **Entity graph** with `MemoryEntity` + `MemoryEntityRelation` schemas
- **Tag-based filtering** with GIN-indexed arrays
- **Importance/decay scoring** with `accessed_at` tracking
- **No vector embeddings yet** — explicitly deferred ("deferred to Phase 3" per `memory/search.ex:32`)
- `MemoryEntry` schema already has `embedding_model` field (unused)

## What's Worth Considering

### 1. Vector Embeddings for Memory Search (HIGH VALUE)

**Gap**: Our FTS is keyword-based. "What did we discuss about project timelines?" won't match a memory stored as "The sprint deadline is March 30th."

**Options**:
| Approach | Complexity | Fit |
|----------|-----------|-----|
| **pgvector** (PostgreSQL extension) | Low | Best fit — stays in existing Postgres, simple `<=>` operator for cosine similarity |
| **ruvector PostgreSQL extension** | Medium | pgvector-compatible but adds self-learning ranking. Heavier dependency (Rust compilation) |
| **ruvector as standalone** | High | Separate service — overkill for our scale |

**Recommendation**: **pgvector first, ruvector later if needed.** pgvector is battle-tested, trivial to add to our existing Postgres, and the `MemoryEntry` schema is already prepped for it. Ruvector's PostgreSQL extension is pgvector-compatible, so migration would be straightforward if we outgrow pgvector.

### 2. Hybrid Search (FTS + Vector + Graph) (HIGH VALUE)

**What ruvector does**: Combines vector similarity with graph traversal for multi-signal ranking.

**We already have the pieces**: FTS (`search_text` tsvector), entity graph (`MemoryEntity`/`MemoryEntityRelation`), and importance scoring. What's missing is the vector signal and a fusion strategy.

**Recommendation**: Implement Reciprocal Rank Fusion (RRF) combining:
1. FTS rank (already have `ts_rank`)
2. Vector cosine similarity (add via pgvector)
3. Entity graph proximity (already have relation traversal)

This is achievable without ruvector — it's a scoring formula, not a database feature.

### 3. Self-Learning / Adaptive Ranking (LOW VALUE — claims don't match code)

**What ruvector claims**: GNN layers learn from query patterns to improve ranking over time.

**What ruvector actually does**: PageRank-weighted cosine similarity re-ranking (0.6 cosine + 0.4 PageRank). No learned parameters, no GNN training. SONA config flags exist but no learning code is present.

**Our simpler equivalent**: We already track `accessed_at` and `importance`. We could:
- Boost memories that get accessed frequently (implicit relevance feedback)
- Decay memories that haven't been accessed (already have `decay_factor`)
- Use the LLM to re-rank top-N results (re-ranking is cheaper than any ML approach)

**Recommendation**: **Skip entirely.** The "self-learning" feature doesn't exist in ruvector's code either. Our `accessed_at` tracking + LLM re-ranking is already more sophisticated than what ruvector actually implements.

### 4. MCP Integration (LOW VALUE for memory, HIGH VALUE elsewhere)

**What ruvector does**: Exposes vector DB as MCP tools for AI assistants.

**Relevance**: We already have a skill-based architecture that serves the same purpose. Our `Memory.Search` module IS the equivalent of an MCP memory tool — it's just internal rather than protocol-based. MCP would be useful for **external tool integration**, not for memory.

### 5. Local LLM Execution (LOW VALUE)

**What ruvector does**: Runs GGUF models locally via `ruvllm` crate.

**Relevance**: We use OpenRouter/OpenAI for LLM routing with per-user credentials. Local execution doesn't fit our multi-tenant architecture. Skip.

### 6. Graph Capabilities (ALREADY COVERED)

**What ruvector does**: Full Cypher query language, hyperedge support.

**What we have**: Entity graph with typed relations, bidirectional traversal, temporal validity (`valid_from`/`valid_to`). Our graph is simpler but purpose-built for memory relations. Cypher would be overkill.

## Concrete Next Steps (if pursuing Phase 3 embeddings)

1. **Add pgvector extension** to PostgreSQL (`CREATE EXTENSION vector`)
2. **Add `embedding` column** to `memory_entries` (`vector(1536)` for OpenAI ada-002, or `vector(768)` for smaller models)
3. **Generate embeddings on memory creation** — call embedding API in `Memory.Store.create_memory_entry/1`
4. **Add vector search to `Memory.Search`** — new `search_by_similarity/3` function using `<=>` (cosine distance) or `<#>` (inner product)
5. **Implement hybrid ranking** — RRF fusion of FTS rank + vector similarity + importance score
6. **Index**: `CREATE INDEX ON memory_entries USING ivfflat (embedding vector_cosine_ops)` for performance

These steps use our existing architecture. No ruvector dependency needed.

## When RuVector Would Make Sense

Honestly, **probably never** given current findings. The core vector DB functionality (HNSW + quantization) is real but is a thin wrapper around `hnsw_rs`. The differentiating features (self-learning, GNN, SONA) don't exist in the code. For our use case:
- pgvector covers vector search within our existing Postgres
- If we outgrow Postgres, Qdrant or Weaviate are more mature dedicated options
- The hybrid search concept (vector + BM25) is worth borrowing as an *idea*, not as a dependency

## Summary

| Feature | Worth It? | How |
|---------|-----------|-----|
| Vector embeddings | **Yes** | pgvector (not ruvector) |
| Hybrid search fusion | **Yes** | RRF formula over existing signals |
| Self-learning ranking | **No** | Doesn't exist in ruvector's code either; our `accessed_at` + LLM re-rank is better |
| MCP integration | **No** (for memory) | Skills architecture covers this |
| Local LLM | **No** | Doesn't fit multi-tenant model |
| Graph queries | **Already have** | Entity graph covers our needs |

**Bottom line**: RuVector's README is far more impressive than its source code. The core vector DB works but is a thin `hnsw_rs` wrapper; the differentiating features (self-learning, GNN, SONA) are absent or stubbed. The most valuable takeaway is the *concept* of hybrid search (vector cosine + BM25/FTS fusion with configurable weights), which we can implement with pgvector + our existing FTS infrastructure. No ruvector dependency warranted.
