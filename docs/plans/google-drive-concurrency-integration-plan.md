# Plan: Google Drive/Docs Concurrency-Safe Write Integration

> Created: 2026-03-04
> Updated: 2026-03-04
> Status: IN PROGRESS
> Scope: Prevent assistant overwrites when Google files are edited concurrently by humans or other processes

## Implemented So Far

### ✅ Phase 1 complete: Drive integration hooks

- `Assistant.Integrations.Google.Drive.update_file_content/5` now supports optional write preconditions
- `Assistant.Integrations.Google.Drive.move_file/5` now supports optional write preconditions
- Added conflict/transient/fatal error classification helper
- Added normalized metadata fields needed for preconditions (`md5_checksum`, `version`)

### ✅ Phase 2 complete: `files.update` protected path

- `files.update` uses preconditioned writes when conflict protection flag is enabled
- Default path remains unchanged when flag is disabled
- Conflict-safe user message added for precondition mismatch

### ✅ Phase 3 complete: `files.archive` protected path

- `files.archive` uses preconditioned move when conflict protection flag is enabled
- Default path remains unchanged when flag is disabled
- Conflict-safe user message added for move conflicts

### ✅ Coordinator + observability complete

- Added `Assistant.Sync.WriteCoordinator` with:
  - optional lease enforcement
  - bounded retry for transient errors
  - telemetry emission (`attempt/retry/success/failure`)
  - optional event hook callback

### ✅ Optional history audit hook complete

- Added `StateStore.record_write_coordinator_event/4`
- Added optional audit persistence from skill writes to `sync_history.details`
- No-op behavior when no synced file mapping exists

### ✅ Worker serialization primitives + idempotent replay complete

- `UpstreamSyncWorker` now supports `write_intent` action with idempotent replay protection
- Replayed `intent_id` jobs are safely skipped
- Intent attempt/success/failure events are persisted via sync history helpers

## Why This Plan Exists

Current write paths perform immediate updates without outbound conflict preconditions:

- `files.update` reads + transforms + writes in one pass
- Drive write calls (`update_file_content/4`, `move_file/4`) do not enforce revision/version preconditions

This can cause silent overwrite when remote content changes between read and write.

## Current Codebase Reality

### Existing write entry points

- `Assistant.Skills.Files.Update` (`lib/assistant/skills/files/update.ex`)
- `Assistant.Skills.Files.Write` (`lib/assistant/skills/files/write.ex`)
- `Assistant.Skills.Files.Archive` (`lib/assistant/skills/files/archive.ex`)
- `Assistant.Integrations.Google.Drive.update_file_content/4` (`lib/assistant/integrations/google/drive.ex`)
- `Assistant.Integrations.Google.Drive.move_file/4` (`lib/assistant/integrations/google/drive.ex`)

### Existing conflict-related primitives

- Inbound sync conflict detection already exists (`lib/assistant/sync/change_detector.ex`)
- Sync state tracking exists (`synced_files`, `sync_history`, `sync_cursors`)
- Conflict notification worker exists (`lib/assistant/sync/workers/conflict_notify_worker.ex`)

### Gap

Conflict logic exists for downstream sync, but not for outbound skill-driven edits.

## Goals

- Never silently overwrite user edits
- Preserve existing skill UX and contracts
- Add conflict safety incrementally behind feature flags
- Reuse sync schemas and history where possible
- Keep rollout reversible

## Non-Goals

- Full CRDT/real-time collaborative editing
- Large redesign of skill interfaces in one release
- Global locking of all files across all operations

## Architecture Decisions

### 1) Optimistic concurrency first

Use remote metadata preconditions (version/modified-time/checksum/revision where available) before write.

### 2) Lease per file for assistant-origin writes

Use short-lived lease key `{user_id, drive_file_id}` to avoid two assistant jobs racing each other.

### 3) Retry only safe cases

Automatic retries only for transient errors and known stale-precondition conflicts.

### 4) User escalation for overlapping edits

If merge safety is uncertain, stop and return an actionable conflict response.

## Proposed Components

### A) Drive conditional write options (backward compatible)

Extend Drive integration API with optional precondition opts, while preserving current call signatures.

Candidate options:

- `expected_modified_time`
- `expected_checksum`
- `expected_version` (if captured)

Behavior:

- If opts are absent: existing behavior unchanged
- If opts are present: perform metadata preflight and reject write on mismatch (`{:error, :conflict}`)

### B) Write coordinator module

New module: `Assistant.Sync.WriteCoordinator`

Responsibilities:

- Acquire/release lease
- Run preflight metadata check
- Execute write operation
- Classify errors (`:conflict`, `:transient`, `:fatal`)
- Retry with bounded policy
- Record sync history entries

### C) Conflict result contract

Standardized conflict result for skills:

- `{:error, :conflict, conflict_meta}` internal
- User-facing message in skill result:
  - "This file changed while I was editing. I paused to avoid overwriting someone."

### D) Intent/audit recording

Use `sync_history.details` for initial intent and outcomes:

- `intent_id`
- `base_remote_modified_at`
- `latest_remote_modified_at`
- `resolution` (`auto_retry_success`, `escalated`, `aborted`)

## State Machine

1. READ_BASE
- Read content + metadata, capture base markers

2. ACQUIRE_LEASE
- Lease by `{user_id, file_id}` (TTL 30s)

3. PRECHECK
- Fetch latest metadata, compare to base markers
- If mismatch -> CONFLICT

4. ATTEMPT_WRITE
- Execute write
- If success -> COMPLETE
- If transient -> RETRY
- If precondition conflict -> CONFLICT
- If fatal -> FAIL

5. RETRY
- Backoff with jitter, max 2 retries

6. CONFLICT
- Return conflict result and log history

7. COMPLETE/FAIL
- Release lease, persist history

## Retry Policy

- Max retries: 2
- Backoff: 250ms then 1s (+ jitter)
- Retry on:
  - transient 429/5xx
  - temporary network failures
- Do not retry on:
  - permission/auth errors
  - invalid patch/input
  - confirmed precondition conflict

## Rollout Plan

### Phase 1 (safest): Integration-layer compatibility hooks

- Add optional precondition opts to Drive update/move APIs
- Add conflict classification helpers
- No caller behavior change yet

### Phase 2: Apply to `files.update` only

- Route `files.update` through `WriteCoordinator`
- Keep existing result shape and status semantics
- Feature flag: `:google_write_conflict_protection`

### Phase 3: Expand to `files.archive` move operations

- Apply preflight checks to re-parent operations where relevant

### Phase 4: Optional worker serialization

- Route long-running outbound writes through `UpstreamSyncWorker`
- Add idempotent replay behavior using `intent_id`

## Feature Flags

- `:google_write_conflict_protection` (default `false`)
- `:google_write_lease_enforcement` (default `false`)
- `:google_write_audit_history` (default `false`)

Flags allow progressive rollout and quick rollback.

## Staging Enablement Checklist

Enable flags incrementally in staging (never all at once):

1. Baseline
  - `google_write_conflict_protection: false`
  - `google_write_lease_enforcement: false`
  - `google_write_audit_history: false`
  - Verify existing write behavior unchanged

2. Conflict protection only
  - `google_write_conflict_protection: true`
  - `google_write_lease_enforcement: false`
  - `google_write_audit_history: false`
  - Validate conflict-safe user messages and zero silent overwrites

3. Add lease enforcement
  - `google_write_conflict_protection: true`
  - `google_write_lease_enforcement: true`
  - `google_write_audit_history: false`
  - Validate concurrent assistant writes serialize cleanly

4. Add audit history
  - `google_write_conflict_protection: true`
  - `google_write_lease_enforcement: true`
  - `google_write_audit_history: true`
  - Validate `sync_history` entries for attempt/retry/success/failure paths

5. Rollback protocol (if needed)
  - Disable in reverse order: audit → lease → conflict protection
  - Confirm writes still function via legacy path

## Runtime Config Snippet

`config/runtime.exs` uses env vars for these rollout flags:

```elixir
config :assistant, :google_write_conflict_protection,
  parse_bool.(System.get_env("GOOGLE_WRITE_CONFLICT_PROTECTION"))

config :assistant, :google_write_lease_enforcement,
  parse_bool.(System.get_env("GOOGLE_WRITE_LEASE_ENFORCEMENT"))

config :assistant, :google_write_audit_history,
  parse_bool.(System.get_env("GOOGLE_WRITE_AUDIT_HISTORY"))
```

Phase env settings:

- Phase 0 baseline:
  - `GOOGLE_WRITE_CONFLICT_PROTECTION=false`
  - `GOOGLE_WRITE_LEASE_ENFORCEMENT=false`
  - `GOOGLE_WRITE_AUDIT_HISTORY=false`
- Phase 1 conflict protection:
  - `GOOGLE_WRITE_CONFLICT_PROTECTION=true`
  - `GOOGLE_WRITE_LEASE_ENFORCEMENT=false`
  - `GOOGLE_WRITE_AUDIT_HISTORY=false`
- Phase 2 + lease:
  - `GOOGLE_WRITE_CONFLICT_PROTECTION=true`
  - `GOOGLE_WRITE_LEASE_ENFORCEMENT=true`
  - `GOOGLE_WRITE_AUDIT_HISTORY=false`
- Phase 3 + audit history:
  - `GOOGLE_WRITE_CONFLICT_PROTECTION=true`
  - `GOOGLE_WRITE_LEASE_ENFORCEMENT=true`
  - `GOOGLE_WRITE_AUDIT_HISTORY=true`

## Testing Plan

### Unit tests

- New `WriteCoordinator` tests:
  - success path
  - precheck conflict
  - transient retry success
  - retry exhaustion
  - fatal error no retry

### Integration tests

- Drive integration tests for optional precondition opts
- Skill tests for `files.update` conflict messaging and no-overwrite behavior

### Regression tests

- Ensure existing `files.update` success behavior unchanged when flag off
- Ensure `files.write` unchanged until explicitly migrated

## Observability

Track counters/histograms:

- `google_write_attempt_total`
- `google_write_conflict_total`
- `google_write_retry_total`
- `google_write_success_total`
- `google_write_failure_total`
- `google_write_latency_ms`

Log fields:

- `user_id`, `file_id`, `intent_id`, `attempt`, `result_type`

## Backward Compatibility and Safety

- Existing APIs remain callable without new opts
- Existing skill result formatting preserved
- Rollout starts with one skill (`files.update`) only
- Fast rollback by disabling feature flag

## Open Questions

- For Google Workspace-native docs, do we add dedicated Docs API patch operations now or defer to preflight+upload model where applicable?
- Should conflict escalation create a user-visible in-app notification event immediately, or stay in skill response first?
- Do we want `intent_id` as a first-class schema/table now, or continue with `sync_history.details` until volume justifies a dedicated table?

## Implementation Checklist

- [x] Add optional precondition opts to Drive write functions
- [x] Add metadata preflight helpers and conflict classification
- [x] Implement `Assistant.Sync.WriteCoordinator`
- [x] Integrate coordinator into `files.update` behind flag
- [x] Integrate coordinator into `files.archive` behind flag
- [x] Add unit and integration tests for Drive/skills/coordinator paths
- [x] Add telemetry events and structured coordinator logging
- [x] Add runtime/env feature flag wiring and staged enablement docs
- [ ] Enable flags in staging and validate conflict/retry/audit behavior with real traffic
- [x] Implement optional worker serialization + idempotent replay via `UpstreamSyncWorker`
- [ ] Roll out to production in phases
