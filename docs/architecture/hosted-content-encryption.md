# Architecture: Hosted Content Encryption with Vault Transit

> Revision 1 — Added 2026-03-19
> Reference plan: `docs/plans/hosted-content-encryption-plan.md`

## Executive Summary

This architecture adds a **hosted-production-only** content encryption layer for retained user data using **HashiCorp Vault Transit** and envelope encryption. It is designed to reduce the usefulness of a raw PostgreSQL breach without breaking the assistant's core retrieval model.

The system keeps the existing Cloak-based encryption path for:
- OAuth tokens
- API keys
- notification/webhook configs
- development
- test
- self-hosted deployments

Hosted production adds a separate content encryption path for:
- conversation messages
- conversation summaries
- memory entries
- task descriptions
- task comments
- optionally other retained free-form content over time

The system does **not** provide end-to-end encryption. The application can still decrypt content in hosted mode when it is authorized to do so.

---

## 1. Threat Model

### Primary Goal

Protect against:
- raw database dumps
- backup leakage
- read access to PostgreSQL without access to the external key system

### Explicit Non-Goal

This architecture does **not** protect against:
- a full application-runtime compromise
- a compromise of both the app and Vault
- a malicious or fully compromised hosted operator
- leakage from embeddings, metadata, or blind indexes

### Security Claim

With this design:
- a PostgreSQL-only attacker should not be able to read retained raw content
- a PostgreSQL-only attacker may still infer some structure from metadata, embeddings, and blind indexes

---

## 2. Deployment Modes

The encryption backend is a runtime deployment choice, not a compile-time environment choice.

| Mode | Target | Description |
|------|--------|-------------|
| `local_cloak` | dev, test, self-hosted prod | Use existing local app-managed path; no Vault requirement |
| `vault_transit` | hosted multi-tenant production | Use Vault Transit-backed envelope encryption for retained content |

### Why not `Mix.env() == :prod`?

Because not all production deployments have the same threat model:
- hosted multi-tenant cloud deployment has higher operator / DB breach risk
- self-hosted single-tenant deployment may accept the existing Cloak path

The runtime deployment model must reflect that difference directly.

---

## 3. Tenant Boundary

The org/workspace boundary for content encryption is `billing_account_id`.

### Rationale

- it already models the shared workspace/account boundary
- it is more stable than channel-specific `user_id`
- it matches the tenant isolation model already used in billing and workspace features

Where content tables do not currently carry `billing_account_id`, hosted encryption should denormalize it onto those rows to avoid repeated joins during encrypt/decrypt and search-partition lookup.

---

## 4. Key Architecture

### Root key service

Use **Vault Transit** as the external cryptographic boundary.

Transit key characteristics:
- mounted under `transit/`
- named key such as `assistant-content`
- `type=aes256-gcm96`
- `derived=true`
- key rotation enabled

Relevant official capabilities:
- encrypt / decrypt
- data key generation
- key derivation context
- key version rotation
- ciphertext rewrap

Sources:
- <https://developer.hashicorp.com/vault/docs/secrets/transit>
- <https://developer.hashicorp.com/vault/api-docs/secret/transit>

### Envelope encryption

The application does not send entire documents to Vault for direct encryption by default. Instead it:

1. requests a plaintext + wrapped DEK from Transit
2. encrypts the payload locally with AEAD
3. stores ciphertext plus the wrapped DEK

This is preferred because it:
- reduces Vault request volume
- avoids large-payload API coupling
- makes key rotation cheaper via `rewrap`

### Per-record encryption

Use a fresh DEK per stored record or chunk, not one long-lived DEK for the entire org.

This reduces blast radius and simplifies future rotation behavior.

---

## 5. Associated Data and Derivation Context

Every encrypted payload must be bound to contextual metadata that is authenticated but not itself secret.

Recommended AAD fields:
- `billing_account_id`
- table name
- field name
- row id
- schema version

Recommended derivation context:

```text
billing_account:<uuid>|table:<table>|field:<field>|v1
```

Recommended AAD payload:

```json
{
  "billing_account_id": "...",
  "table": "messages",
  "field": "content",
  "row_id": "...",
  "version": 1
}
```

This prevents ciphertext from being safely copied between:
- orgs
- tables
- fields
- rows

without decryption failure.

---

## 6. Data Flow

### Hosted write path

```text
plaintext content
  -> resolve billing_account_id
  -> build derivation context + AAD
  -> Vault Transit datakey/plaintext
  -> local AES-GCM encrypt with plaintext DEK
  -> generate embeddings from plaintext
  -> generate blind keyword index digests
  -> persist ciphertext + wrapped DEK + nonce + metadata
  -> discard plaintext DEK and plaintext body
```

### Hosted read path

```text
query via metadata / blind index / embeddings
  -> fetch candidate rows
  -> unwrap DEK through Vault Transit
  -> local AES-GCM decrypt
  -> return plaintext to authorized caller
```

### Self-hosted / local path

```text
plaintext content
  -> existing local path
  -> current behavior retained
```

---

## 7. Search Architecture

Hosted mode cannot rely on plaintext PostgreSQL full-text search over encrypted bodies.

Current plaintext search is implemented through:
- memory `tsvector` search in [lib/assistant/memory/search.ex](/Users/jrosenbaum/Documents/Code/Synaptic-Assistant/lib/assistant/memory/search.ex#L21)
- transcript preview and `ILIKE` search in [lib/assistant/transcripts.ex](/Users/jrosenbaum/Documents/Code/Synaptic-Assistant/lib/assistant/transcripts.ex#L23)

Hosted mode replaces this with a hybrid of:

### A. Embeddings

Purpose:
- semantic retrieval
- concept/topic matching

Leakage:
- approximate semantic information
- document clustering signals

### B. Blind keyword index

Purpose:
- keyword and exact-ish term lookup without storing plaintext terms

Mechanism:
1. tokenize and normalize plaintext in app code
2. HMAC each normalized term with an org-scoped key
3. store digests in an index table
4. search by applying the same normalization + HMAC to query terms

Leakage:
- repeated-term equality
- term frequency
- shared-term structure across docs

### C. Minimal plaintext metadata

Examples:
- created_at
- updated_at
- category
- source_type
- maybe tags, titles, filenames if acceptable

### Hosted hybrid retrieval model

```text
metadata filters
  + blind keyword matches
  + embedding similarity
  -> candidate set
  -> decrypt top results only
```

This means hosted mode keeps search, but no longer keeps a plaintext body index in Postgres.

---

## 8. Affected Repo Areas

### Directly affected content systems

- `messages.content`
- `conversations.summary`
- `memory_entries.content`
- `tasks.description`
- `task_comments.content`

### Search systems that must change

- `Assistant.Memory.Search`
- `Assistant.Transcripts`

### Side channels that must be reviewed

- trajectory export in [lib/assistant/analytics/trajectory_exporter.ex](/Users/jrosenbaum/Documents/Code/Synaptic-Assistant/lib/assistant/analytics/trajectory_exporter.ex#L17)
- execution logs
- tool payload persistence
- any disk-based cache or export path that writes plaintext copies

### Existing Cloak path that stays

Current Cloak-based field encryption remains appropriate for secret-bearing fields such as:
- `settings_users.openrouter_api_key`
- `settings_users.openai_api_key`
- `oauth_tokens.refresh_token`
- `integration_settings.value`
- `notification_channels.config`

Current runtime config lives in [config/runtime.exs](/Users/jrosenbaum/Documents/Code/Synaptic-Assistant/config/runtime.exs#L226).

---

## 9. Vault Integration Model

### Auth

Hosted deployments should use:
- Vault Agent
- AppRole auto-auth
- narrow service policy

Avoid:
- root token in env
- broad reusable app tokens

Relevant docs:
- <https://developer.hashicorp.com/vault/docs/agent/autoauth/methods/approle>
- <https://developer.hashicorp.com/vault/docs/concepts/policies>

### Policy model

Policies are deny-by-default, which fits the desired service boundary.

Recommended capabilities:

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

If direct Transit encrypt/decrypt is used for small fields, add only the exact additional paths needed.

---

## 10. Rotation and Rewrap

Vault Transit supports key rotation and ciphertext rewrap.

Recommended model:

1. rotate the Transit key version
2. keep reading existing wrapped DEKs
3. background job rewrites wrapped DEKs through `rewrap`
4. new writes use the latest key version immediately

Important distinction:
- if only the wrapping key changes, raw content does not need full re-encryption
- only the wrapped DEK changes

This is one of the main reasons to prefer envelope encryption over direct full-payload Transit encryption.

---

## 11. Operational Notes

### Caching

Hosted mode may keep a short-lived in-memory DEK cache to reduce Vault round-trips.

Constraints:
- small TTL
- bounded cache size
- no persistence
- purge on node restart

### Failure handling

If Vault is unavailable in hosted mode:
- new hosted writes should fail closed
- hosted reads of encrypted content should fail closed
- the system should emit explicit operational alerts

Fail-open behavior would defeat the point of the architecture.

### Auditability

Vault access logs become part of the security model:
- key unwrap operations
- rewrap jobs
- service auth events

---

## 12. Tradeoffs

### What improves

- raw DB dumps no longer reveal retained plaintext content
- backups become less dangerous
- tenant blast radius is reduced through org-scoped derivation context
- key management moves out of PostgreSQL and app config

### What gets worse

- search architecture is more complex
- transcript list/search loses plaintext SQL convenience in hosted mode
- Vault becomes an operational dependency
- metadata / embedding leakage still exists
- debugging stored content becomes more deliberate

### What does not change

- the application can still decrypt authorized content
- hosted admins can still view content through approved app flows
- this is not zero-knowledge storage

---

## 13. Recommended Rollout

1. Add runtime provider abstraction.
2. Keep `local_cloak` as default for all environments initially.
3. Enable `vault_transit` only in hosted production.
4. Migrate one content path at a time, starting with `messages.content`.
5. Replace hosted plaintext search with blind index + embeddings.
6. Backfill and verify.
7. Remove hosted plaintext columns only after sustained production validation.

---

## 14. Final Position

This architecture is the recommended compromise for a hosted, multi-tenant assistant that needs:
- strong protection against raw database compromise
- preserved server-side retrieval
- no hard dependency on AWS or GCP KMS

It is intentionally **not** the strongest possible privacy model. It is the strongest practical model that preserves the current product shape.
