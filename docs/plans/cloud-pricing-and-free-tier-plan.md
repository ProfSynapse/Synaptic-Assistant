# Implementation Plan: Cloud Pricing + Free Tier Storage Model

> Created: 2026-03-17
> Status: DRAFT
> Direction: Keep pricing simple with one paid seat price, storage included in the seat, and per-GB overage above the included amount.

## Summary

This plan defines a simple initial cloud pricing model for Synaptic Assistant:

- `Free`: `25 MB` included storage
- `Pro`: `$18/user/month`
- `Pro` includes `10 GB` storage per user
- `Overage`: `$1/GB-month` above `10 GB`

Free tier access is limited to these storage connectors:

- Google
- Microsoft
- Box

All other connectors are paid-only.

The free tier does not allow overage. When a free user reaches `25 MB`, new sync or storage writes should stop and the UI should prompt an upgrade.

## Why This Model

The product’s current architecture makes storage the clearest cost driver when inference is user-provided:

- Google Docs and Slides are converted to Markdown, and Sheets to CSV in `lib/assistant/sync/converter.ex`
- synced file content is stored directly in `synced_files.content` via `lib/assistant/schemas/synced_file.ex`
- the sync workspace is database-backed in `lib/assistant/sync/file_manager.ex`
- conversations and tool traces are stored in `lib/assistant/schemas/message.ex`
- long-term memory content is stored in `lib/assistant/schemas/memory_entry.ex`

This means the cloud product is not only hosting auth and orchestration. It is also retaining:

- synced document content
- conversation history
- memory records
- related indexing and metadata overhead

That makes a seat price plus storage cap more defensible than a pure flat seat with unlimited storage.

## Chosen Pricing

### Free

- `25 MB` total included storage
- available connectors:
  - Google
  - Microsoft
  - Box
- no storage overage
- upgrade required once limit is reached

### Pro

- `$18/user/month`
- `10 GB` included storage
- all connectors available
- `$1/GB-month` above `10 GB`

## Metering Rules

### Billing Metric

Storage should be billed on:

- average daily stored GB during the billing month

This is easier to defend than peak billing and better matches customer expectations.

### Storage Scope

Initial storage metering should include customer-visible retained content:

- synced file content
- conversation message content
- message tool payloads that are persisted for product value
- memory content

Do not bill customers for internal-only overhead directly:

- indexes
- WAL / backups
- platform snapshots
- operational logs

Those costs are covered by the seat price and overage margin.

### Free Tier Enforcement

At the free limit:

- block new sync downloads
- block new uploads / writes that increase retained storage
- keep reads available
- show upgrade messaging in settings and connector flows

## Storage Math

These assumptions are intentionally simple and should be revised after real production data is available:

- Markdown / text content: about `3.5 KB` per page
- Chat message / turn: about `1.5 KB`
- Memory entry: about `0.8 KB`
- Production overhead reserve: about `20%`

The `20%` reserve is meant to account for:

- row and index overhead
- encryption overhead
- schema metadata
- imperfect sizing assumptions

### Realistic Free-Tier Mix

Assume the free user’s retained storage is:

- `65%` synced Markdown / CSV / text documents
- `25%` chat history
- `10%` memories

At `25 MB`, that implies:

#### Raw Content Estimate

- Markdown/text docs: `16.25 MB`
- Chats: `6.25 MB`
- Memories: `2.5 MB`

Approximate capacity:

- `4,754` Markdown pages
- `4,267` chat turns
- `3,200` memory entries

#### Conservative Estimate With 20% Overhead Reserve

Usable content budget: about `20 MB`

Approximate capacity:

- `3,803` Markdown pages
- `3,413` chat turns
- `2,560` memory entries

## Interpretation

Even `25 MB` is still meaningful for text-heavy usage because Markdown, CSV, and chat transcripts are dense.

That is acceptable if the goal of free is:

- let users try real sync and memory features
- avoid making free feel fake
- still create a clear upgrade boundary before free becomes a permanent home

This plan intentionally does not try to make storage alone do all upgrade work. Packaging also matters:

- free only gets Google, Microsoft, and Box
- all other connectors are paid

If future conversion from free to paid is weak, the next tightening lever should be product packaging before lowering storage again:

- reduce free to one storage connector
- slow free sync cadence
- cap free file count

## Paid Tier Margin Rationale

Current provider economics still support this model comfortably.

Working assumption:

- app hosting on Fly.io
- PostgreSQL on Neon

At current listed pricing on 2026-03-17:

- Neon storage is materially below the proposed `$1/GB-month` overage
- Fly app compute is low enough that a `$18` seat price should absorb orchestration, auth, sync polling, support, and storage for typical users

This gives room for:

- database overhead
- support burden
- sync background jobs
- future memory growth

## Risks

### Text Storage Is Cheaper Than Most Users Expect

Markdown and chat text compress the economics heavily in the product’s favor. Free users may get substantial value from `25 MB`.

### Raw Binary Files Change the Equation

If free users can store many PDFs or images, they will hit the cap much faster. This is acceptable, but product messaging should make it clear that the free tier is storage-limited.

### Embeddings Would Change Memory Economics

Today, memory entries do not store a real vector column. If vector embeddings are added later, retained memory costs will rise materially and this pricing model should be revisited.

## Implementation Plan

### Phase 1: Product Rules

1. Add plan definitions for `free` and `pro`.
2. Add connector allowlisting by plan.
3. Add a free-tier storage cap check before sync and retained-write operations.
4. Add upgrade messaging in settings, connector flows, and storage status UI.

### Phase 2: Metering

1. Add a storage metering query that computes retained bytes per user.
2. Snapshot daily retained usage for billing.
3. Compute monthly average stored GB from daily snapshots.
4. Expose usage and projected bill in settings.

### Phase 3: Billing

1. Add Stripe customer and subscription records.
2. Add one paid seat price for Pro.
3. Add metered overage billing for storage above included capacity.
4. Keep free tier hard-capped with no overage billing.

## Recommended Product Copy

### Pricing Page

Free

- `25 MB included`
- Google, Microsoft, and Box

Pro

- `$18/user/month`
- `10 GB included`
- all connectors
- `$1/GB-month` over `10 GB`

### Billing Clarification

Bill storage on monthly average retained storage, not peak storage.

## Open Questions

1. Should free users get all three of Google, Microsoft, and Box, or only one of those connectors?
2. Should free sync cadence be slower than paid sync cadence?
3. Should the product meter message tool payloads fully, or only user-visible transcript text?
4. Should storage usage be shown as decimal GB or binary GiB in the UI?

## Recommendation

Ship this exact model first:

- `Free`: `25 MB`, Google + Microsoft + Box only
- `Pro`: `$18/user/month`, `10 GB` included
- `Overage`: `$1/GB-month`

Then revisit after observing:

- free-to-paid conversion
- average retained storage per active user
- whether raw binaries or text-heavy workspaces dominate usage
