# RuVector Review: Relevance to Synaptic-Assistant

**Date**: 2026-03-19
**Repo**: https://github.com/ruvnet/ruvector
**Reviewer**: Claude Code

## What is RuVector?

A Rust-based self-learning vector database and AI operating system. Key claims:
- HNSW vector indexing with SIMD acceleration
- Graph Neural Networks (GNNs) that adapt search rankings from usage patterns
- PostgreSQL extension (230+ SQL functions, pgvector-compatible)
- Local LLM execution (GGUF models, WASM-compatible)
- `.rvf` cognitive container format (boots in 125ms)
- MCP (Model Context Protocol) support
- 90+ Rust crates covering core, graph, attention, solvers, postgres extension

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

### 3. Self-Learning / Adaptive Ranking (MEDIUM VALUE, HIGH COMPLEXITY)

**What ruvector does**: GNN layers learn from query patterns to improve ranking over time.

**Our simpler equivalent**: We already track `accessed_at` and `importance`. We could:
- Boost memories that get accessed frequently (implicit relevance feedback)
- Decay memories that haven't been accessed (already have `decay_factor`)
- Use the LLM to re-rank top-N results (re-ranking is cheaper than GNN training)

**Recommendation**: **Skip GNN complexity.** Our `accessed_at` tracking + LLM re-ranking gives 80% of the benefit at 5% of the complexity. Revisit if memory corpus exceeds ~100K entries per user.

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

- If memory corpus grows to millions of entries per user and pgvector performance degrades
- If we need the self-learning ranking to reduce LLM re-ranking costs at scale
- If we want to offer vector search as a user-facing feature (not just internal memory)
- If we adopt MCP as a standard protocol for external tool integration

## Summary

| Feature | Worth It? | How |
|---------|-----------|-----|
| Vector embeddings | **Yes** | pgvector (not ruvector) |
| Hybrid search fusion | **Yes** | RRF formula over existing signals |
| Self-learning ranking | **No** (for now) | `accessed_at` + LLM re-rank suffices |
| MCP integration | **No** (for memory) | Skills architecture covers this |
| Local LLM | **No** | Doesn't fit multi-tenant model |
| Graph queries | **Already have** | Entity graph covers our needs |

**Bottom line**: RuVector is an impressive project but it's solving problems at a scale we don't have yet. The most valuable takeaway is the *concept* of hybrid search (FTS + vector + graph), which we can implement with pgvector + our existing infrastructure. If we outgrow pgvector, ruvector's PostgreSQL extension is a compatible upgrade path.
