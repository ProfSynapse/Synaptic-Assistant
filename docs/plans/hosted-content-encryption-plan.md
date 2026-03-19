# Implementation Plan: Hosted Content Encryption with Vault Transit

> Generated on 2026-03-19
> Status: DRAFT

<!-- Status Lifecycle:
     DRAFT -> APPROVED -> IN_PROGRESS -> IMPLEMENTED
           \-> SUPERSEDED
           \-> BLOCKED
-->

## Summary

Add a **hosted-production-only** content encryption path for retained user data using **HashiCorp Vault Transit** and envelope encryption scoped by `billing_account_id`.

This plan does **not** replace the current Cloak setup for small secret fields or self-hosted deployments. Instead:

- **Hosted production** uses `vault_transit` mode for retained user content.
- **Self-hosted prod**, **dev**, and **test** continue to use the existing `local_cloak` path.
- Raw content is encrypted before it reaches PostgreSQL.
- Search remains available through **embeddings** plus a **blind keyword index** derived at ingest time.

The goal is to make a raw database breach materially less useful while preserving retrieval, admin workflows, and hybrid search.

Reference architecture: `docs/architecture/hosted-content-encryption.md`

---

## DAG + QDCL Orchestration

This plan is intentionally decomposed for parallel execution using a staged DAG and a lightweight QDCL method.

**QDCL**
- **Qualify**: identify the smallest production-hardening slice that improves security without forcing a full search rewrite
- **Depend**: make shared prerequisites explicit before parallel work starts
- **Cut**: isolate write sets so workstreams do not touch the same files or schema steps at the same time
- **Lock**: gate the critical path with explicit phase checks before advancing

### DAG Nodes

| Node | Scope | Depends On | Owner Boundary |
|------|-------|------------|----------------|
| `A0` | Runtime mode split (`local_cloak` vs `vault_transit`) | none | runtime config + provider facade |
| `A1` | Vault provider, cache, boot/failure contract | `A0` | runtime/provider modules only |
| `B0` | Schema foundation: encrypted payload columns, `billing_account_id`, blind-index table | `A0` | migrations + schemas only |
| `B1` | Messages path: `messages.content` + hosted transcript behavior | `A1`, `B0` | message schema + transcript query path |
| `B2` | Conversation summaries path | `A1`, `B0` | conversation schema + summary reads |
| `C0` | Memory path encryption + blind index ingestion | `A1`, `B0` | memory schema/store/indexing only |
| `C1` | Hosted memory retrieval switch: blind index + embeddings | `C0` | memory search modules only |
| `D0` | Side-channel cleanup: transcript preview, memory explorer, trajectory export | `A0` | export/admin/search surfaces only |
| `E0` | Tasks/comments and second-order content | `A1`, `B0` | task-related schemas/contexts |
| `F0` | Plaintext removal | `B1`, `B2`, `C1`, `D0`, `E0` | cleanup only after parity |

### Critical Path

Recommended critical path:

```text
A0 -> A1 -> B0 -> B1 -> C0 -> C1 -> E0 -> F0
```

Parallel branches:

```text
B0 -> B2
A0 -> D0
```

### Smallest Safe Phase-1 Slice

The smallest safe hosted-production slice is:

1. `A0` runtime split
2. `A1` Vault provider foundation
3. `B0` minimal schema support for encrypted message payloads
4. `B1` message encryption dual-write
5. `D0` transcript/trajectory side-channel guardrails needed to avoid immediate plaintext leaks

That phase intentionally does **not** include hosted memory encryption yet.

---

## Goals

- Encrypt retained user content at rest for hosted production.
- Scope content encryption by org/workspace using `billing_account_id`.
- Keep keys outside PostgreSQL.
- Preserve semantic retrieval and keyword retrieval without storing plaintext bodies.
- Keep existing Cloak-based secret field encryption for:
  - OAuth tokens
  - API keys
  - notification configs
  - self-hosted deployments

## Non-Goals

- No end-to-end or client-side encryption.
- No claim that a compromised app runtime cannot read user data.
- No attempt to hide all leakage from embeddings, tags, or metadata.
- No requirement that self-hosted installations run Vault.
- No attempt to keep PostgreSQL `tsvector` search over raw content in hosted mode.

---

## Specialist Perspectives

### Preparation Phase
**Effort**: Medium

#### Research Confirmed
- [x] Vault Transit is intended for application-side encryption while storing ciphertext in the primary datastore.
- [x] Transit supports key derivation, `datakey` generation, rotation, and `rewrap`.
- [x] Vault policies are deny-by-default.
- [x] AppRole is the appropriate machine-auth pattern for hosted deployments.
- [x] Current memory search relies on plaintext `search_text` / `tsvector`.
- [x] Current transcript search and preview rely on plaintext message content.

#### Existing Constraints in This Repo
- `Assistant.Vault` + `cloak_ecto` currently provide app-wide field encryption for secret-bearing columns.
- `memory_entries.search_text` is trigger-populated from plaintext `content`.
- transcript preview and free-text filtering currently query `messages.content` directly.
- trajectory export currently writes plaintext JSONL to disk.
- `billing_account_id` is the cleanest org boundary already present in the schema graph.

#### External References
- Vault Transit docs: <https://developer.hashicorp.com/vault/docs/secrets/transit>
- Transit API: <https://developer.hashicorp.com/vault/api-docs/secret/transit>
- Vault Policies: <https://developer.hashicorp.com/vault/docs/concepts/policies>
- Vault Agent AppRole auto-auth: <https://developer.hashicorp.com/vault/docs/agent/autoauth/methods/approle>

---

### Architecture Phase
**Effort**: High

#### Deployment Modes

| Mode | Use Case | Content Crypto Backend |
|------|----------|------------------------|
| `local_cloak` | dev, test, self-hosted prod | Existing app-local encryption / plaintext search path |
| `vault_transit` | hosted multi-tenant production | Vault Transit + envelope encryption + blind index |

#### Components Affected

| Component | Change Type | Impact |
|-----------|-------------|--------|
| `Assistant.Encryption` | New facade | Runtime-selected content crypto backend |
| `Assistant.Encryption.Provider` | New behaviour | `encrypt/decrypt/index_terms` contract |
| `Assistant.Encryption.LocalProvider` | New | Compatibility path for self-hosted/dev/test |
| `Assistant.Encryption.VaultTransitProvider` | New | Hosted production envelope encryption |
| `Assistant.Encryption.Context` | New | Canonical org/table/field/row AAD builder |
| `Assistant.Encryption.Cache` | New | Short-lived DEK cache for hosted mode |
| `Message` schema | Modify | Replace plaintext `content` storage with envelope-encrypted payload in hosted mode |
| `Conversation` schema | Modify | Encrypt `summary` in hosted mode |
| `MemoryEntry` schema | Modify | Encrypt raw `content`, replace plaintext FTS with blind term index |
| `Task` schema | Modify | Encrypt `description` in hosted mode |
| `TaskComment` schema | Modify | Encrypt `content` in hosted mode |
| `Transcripts` | Modify | Remove DB-side plaintext preview/search in hosted mode |
| `Memory.Search` | Modify | Replace plaintext FTS with blind-index + vector hybrid path in hosted mode |
| `TrajectoryExporter` | Modify | Disable or encrypt export artifacts in hosted mode |
| `Application` | Modify | Start encryption cache/provider support |

#### Design Approach

**Hosted production path**

1. Resolve `billing_account_id`.
2. Build AAD / derivation context from:
   - `billing_account_id`
   - table
   - field
   - row id
   - schema version
3. Call Vault Transit `datakey/plaintext/:name`.
4. Use returned plaintext DEK to encrypt the payload locally with AEAD.
5. Store:
   - ciphertext
   - nonce
   - wrapped DEK
   - key version
   - algorithm/version metadata
6. Derive blind term digests for keyword lookup and store them separately.
7. Generate embeddings from plaintext before discard.

**Hosted read path**

1. Query by metadata, blind term index, and/or embeddings.
2. Fetch candidate encrypted rows.
3. Unwrap DEK through Vault Transit.
4. Decrypt in app memory.
5. Return plaintext only to authorized flows.

#### Key Decisions

| Decision | Options | Recommendation | Rationale |
|----------|---------|----------------|-----------|
| Org boundary | `user_id`, `settings_user_id`, `billing_account_id` | **`billing_account_id`** | Already models workspace/tenant boundary |
| Key service | AWS/GCP KMS, Vault Transit, local key only | **Vault Transit** | Cloud-agnostic, production-friendly, matches hosted requirement |
| Encryption mode | direct Vault encrypt, envelope encryption | **Envelope encryption** | Lower Vault load, works for larger payloads, simpler row storage model |
| Search strategy | plaintext FTS, embeddings only, blind index + embeddings | **Blind keyword index + embeddings** | Preserves exact-ish lookup and semantic retrieval without plaintext bodies |
| Hosted rollout | in-place replacement, parallel columns | **Parallel columns + dual write** | Safer migration and rollback |
| Cloak usage | replace all Cloak, keep only Vault | **Keep Cloak for secret fields** | Existing implementation is still appropriate for secrets and self-hosted installs |

#### Search Model in Hosted Mode

Raw content is encrypted. Search uses separate derived artifacts:

- **Embeddings** for semantic retrieval
- **Blind keyword index** for exact-ish term retrieval
- **Minimal metadata** for filtering and ranking

Blind keyword index rules:
- tokenize + normalize in app code at ingest time
- HMAC each normalized term with an org-scoped blind-index key
- store term digests, optional document frequency / term frequency counts
- query by applying the same normalization + HMAC to search terms

Tradeoff:
- preserves keyword lookup
- leaks equality / frequency / shared-term structure
- avoids storing raw searchable text in Postgres

#### Hosted-Mode Data Shapes

Example encrypted field storage shape:

```elixir
%{
  ciphertext: binary(),
  nonce: binary(),
  wrapped_dek: binary(),
  dek_version: integer(),
  algorithm: "aes_256_gcm",
  aad_version: 1
}
```

Example blind index row:

```elixir
%{
  billing_account_id: Ecto.UUID.t(),
  owner_type: "memory_entry",
  owner_id: Ecto.UUID.t(),
  field: "content",
  term_digest: binary(),
  term_frequency: integer()
}
```

---

### Code Phase
**Effort**: High

#### Files to Create

| File | Purpose |
|------|---------|
| `lib/assistant/encryption.ex` | Public facade for content encryption |
| `lib/assistant/encryption/provider.ex` | Behaviour for runtime-selected backend |
| `lib/assistant/encryption/local_provider.ex` | Self-hosted/dev/test path |
| `lib/assistant/encryption/vault_transit_provider.ex` | Hosted production Vault backend |
| `lib/assistant/encryption/context.ex` | Build AAD / derivation context |
| `lib/assistant/encryption/cache.ex` | ETS-backed short-lived DEK cache |
| `lib/assistant/encryption/blind_index.ex` | Tokenization + HMAC term digest generation |
| `lib/assistant/schemas/encrypted_payload.ex` | Embedded schema or helper struct for ciphertext metadata |
| `lib/assistant/schemas/content_term.ex` | Blind keyword index schema |
| `lib/assistant/search/blind_index.ex` | Query helpers for term-digest retrieval |
| `docs/architecture/hosted-content-encryption.md` | Long-lived architecture reference |

#### Files to Modify

| File | Changes |
|------|---------|
| `lib/assistant/application.ex` | Start encryption cache/provider support |
| `config/runtime.exs` | Add runtime `content_crypto` mode selection and Vault config |
| `mix.exs` | Add Vault client dependency only if we adopt one; otherwise use existing `Req` |
| `lib/assistant/schemas/message.ex` | Add encrypted payload fields for `content` |
| `lib/assistant/schemas/conversation.ex` | Add encrypted payload fields for `summary` |
| `lib/assistant/schemas/memory_entry.ex` | Add encrypted payload fields and remove hosted reliance on plaintext FTS |
| `lib/assistant/schemas/task.ex` | Add encrypted payload fields for `description` |
| `lib/assistant/schemas/task_comment.ex` | Add encrypted payload fields for `content` |
| `lib/assistant/memory/store.ex` | Encrypt on write, decrypt on read, dual-write during migration |
| `lib/assistant/memory/search.ex` | Hosted-mode blind keyword + vector retrieval path |
| `lib/assistant/transcripts.ex` | Hosted-safe preview/search behavior |
| `lib/assistant/analytics/trajectory_exporter.ex` | Disable or encrypt output in hosted mode |
| `lib/assistant/embeddings/embed_memory_worker.ex` | Generate embeddings from decrypted or pre-encryption plaintext |

#### Database Migrations

1. **Core encrypted payload columns**
   - `messages`
   - `conversations`
   - `memory_entries`
   - `tasks`
   - `task_comments`

2. **Add `billing_account_id` to content-heavy tables**
   - denormalized for crypto context and search partitioning

3. **Blind index table**
   - `content_terms`
   - indexes on `[billing_account_id, owner_type, field, term_digest]`

4. **Optional migration table**
   - `content_crypto_backfill_jobs` or rely on Oban args only

5. **Eventually remove hosted plaintext search artifacts**
   - `memory_entries.search_text`
   - hosted-only query paths that rely on raw plaintext body search

#### Runtime Config

Proposed env vars:

```bash
CONTENT_CRYPTO_MODE=local_cloak|vault_transit

VAULT_ADDR=https://vault.example.com
VAULT_TRANSIT_MOUNT=transit
VAULT_TRANSIT_KEY=assistant-content
VAULT_AUTH_MODE=agent|token
VAULT_TOKEN=...
VAULT_NAMESPACE=...

CONTENT_CRYPTO_DEK_CACHE_TTL_MS=300000
CONTENT_CRYPTO_DEK_CACHE_MAX=10000
```

Self-hosted recommendation:
- default `CONTENT_CRYPTO_MODE=local_cloak`

Hosted production recommendation:
- require `CONTENT_CRYPTO_MODE=vault_transit`

#### Vault Layout

Transit key:
- `transit/keys/assistant-content`
- `type=aes256-gcm96`
- `derived=true`
- auto-rotation enabled

Recommended app policy:

```hcl
path "transit/datakey/plaintext/assistant-content" {
  capabilities = ["update"]
}

path "transit/decrypt/assistant-content" {
  capabilities = ["update"]
}

path "transit/rewrap/assistant-content" {
  capabilities = ["update"]
}
```

Auth recommendation:
- Vault Agent + AppRole for hosted deployments
- avoid long-lived root tokens or broad app tokens

#### Implementation Sequence

**Stage A: Runtime foundation**
1. `A0` Add explicit runtime `content_crypto` mode.
2. Add encryption facade + provider behaviour.
3. Implement `LocalProvider` as the compatibility backend for self-hosted/dev/test.
4. `A1` Implement `VaultTransitProvider` against Transit API using `Req`.
5. Add short-lived encryption cache child and fail-closed boot/runtime behavior in `vault_transit` mode.

**Stage B: Shared schema foundation**
6. `B0` Add `billing_account_id` to content-bearing tables where needed.
7. Add encrypted payload columns for phase-1 tables.
8. Add blind-index table (`content_terms`) even if only memory uses it later.

**Stage C: Smallest safe hosted slice**
9. `B1` Dual-write `messages.content` to encrypted payload columns.
10. Decrypt on transcript detail reads.
11. `D0` Remove hosted plaintext transcript preview/search.
12. `D0` Disable or rework trajectory export and other obvious plaintext side channels for hosted mode.

**Stage D: Low-coupling follow-up**
13. `B2` Encrypt `conversations.summary`.
14. Backfill message and summary ciphertext coverage.

**Stage E: Memory path**
15. `C0` Add encrypted content columns to `memory_entries`.
16. Populate blind keyword index from `title`, `content`, and `search_queries`.
17. Dual-write plaintext memory + encrypted memory + blind index.
18. Generate embeddings from plaintext before discard.
19. `C1` Replace hosted memory FTS with blind index + embeddings + metadata retrieval.
20. Backfill existing memories and validate hosted retrieval parity.

**Stage F: Secondary content**
21. `E0` Encrypt task descriptions and comments.
22. Audit `execution_logs`, `tool_results`, and similar persisted payloads.
23. Decide whether `synced_files.content` remains transitional Cloak scope or migrates into the unified hosted model later.

**Stage G: Rotation and cleanup**
24. Add operator tooling for Vault key rotate + wrapped DEK rewrap.
25. Add integrity checks and repair jobs.
26. `F0` Only after parity and rollback drills: stop plaintext writes, switch hosted reads to encrypted-only, and remove plaintext search artifacts.

---

### Test Phase
**Effort**: High

#### Test Scenarios

| Scenario | Type | Priority |
|----------|------|----------|
| `local_cloak` mode keeps current behavior in dev/test | Integration | P0 |
| `vault_transit` encrypts raw payload before DB write | Integration | P0 |
| DB row with ciphertext cannot be decoded without provider | Unit | P0 |
| AAD mismatch causes decrypt failure | Unit | P0 |
| wrong `billing_account_id` context cannot decrypt another org's row | Integration | P0 |
| blind index query returns correct candidate rows | Integration | P0 |
| embeddings + blind index hybrid search still returns relevant memories | Integration | P1 |
| transcript detail decrypts messages in hosted mode | Integration | P1 |
| transcript list avoids plaintext preview in hosted mode | Integration | P1 |
| trajectory export disabled or encrypted in hosted mode | Integration | P1 |
| Vault timeouts / failures degrade safely | Integration | P1 |
| wrapped DEK rewrap path works after Transit rotation | Integration | P1 |
| self-hosted production on `local_cloak` does not require Vault | Integration | P0 |

#### Coverage Targets

| Module | Target | Rationale |
|--------|--------|-----------|
| `Assistant.Encryption.VaultTransitProvider` | 90%+ | CRITICAL — external crypto boundary |
| `Assistant.Encryption.BlindIndex` | 90%+ | CRITICAL — keyword retrieval correctness |
| `Assistant.Memory.Search` hosted path | 85%+ | HIGH — user-facing retrieval path |
| `Assistant.Transcripts` hosted path | 85%+ | HIGH — admin UX path must not regress |

---

## What Must Change in Current Behavior

### 1. Memory FTS

Current implementation uses plaintext `search_text` in PostgreSQL.

Hosted mode must replace this with:
- blind term index lookup
- embedding retrieval
- metadata filters

### 2. Transcript Preview and Text Search

Current implementation in `Transcripts` uses plaintext SQL preview and `ILIKE` over `messages.content`.

Hosted mode must:
- remove free-text SQL over raw message body
- provide metadata-only list filtering
- decrypt only on transcript detail retrieval

### 3. Export Side Channels

Current trajectory export writes plaintext JSONL to disk.

Hosted mode must either:
- disable exports by default, or
- encrypt export artifacts with the same content crypto system

---

## Rollout Strategy

### Safe rollout

1. Ship provider abstraction with `local_cloak` default.
2. Deploy hosted environments with `vault_transit` disabled but configured.
3. Enable dual-write for one table at a time.
4. Run backfill jobs.
5. Verify decrypt/read/search parity.
6. Switch reads to encrypted fields.
7. Remove plaintext columns later.

### Rollback

During dual-write:
- reads can fall back to plaintext columns
- blind index can be rebuilt from plaintext

After plaintext column removal:
- rollback requires a verified decrypt/export path before schema rollback

---

## Open Questions

- Should blind indexing apply to full messages or only memory/document chunks?
- Do we want exact phrase search, or are token-level keyword matches sufficient?
- Should hosted admin transcript search support decrypt-and-scan for a single selected conversation only?
- Should `execution_logs.result` and tool payloads be in scope for phase 1 or deferred?
- Should synced document titles / filenames remain plaintext for UX, or be moved into encrypted metadata with a separate displayed alias?

---

## Final Recommendation

Proceed with:
- **Vault Transit + envelope encryption** for hosted production retained content
- **blind keyword index + embeddings** for hosted search
- **existing Cloak path** retained for self-hosted/dev/test and small secret fields

This is the strongest practical improvement available without redesigning the product around end-to-end encryption.
