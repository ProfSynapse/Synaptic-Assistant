# Spec: Google Drive Sync UI & Granular Targeting

> Created: 2026-03-04
> Status: PROPOSED
> Direction: Granular sync selection within the Google Workspace integration card, with robust auto-retry and a visible sync history.

## Summary

The current Google Drive sync implementation provides a solid backend foundation for polling incremental changes (via `startPageToken`). However, it lacks frontend visibility and limits users to syncing entire drives. 

This spec outlines the next evolution of the Drive Sync feature:
1. **Granular Selection:** Users can choose to sync entire Drives, specific Folders, or individual Files.
2. **Settings UI Integration:** The interface will live directly within the existing Google Workspace integration card.
3. **Sync Visibility:** A "Recently Synced" list to show exactly what data the assistant has ingested.
4. **Resilience:** Automatic exponential backoff for failed files, plus manual retry constraints.

## 1. UX / UI Design

### Placement
The UI will be an expansion of the current `DriveSettings` component inside the Google Integration page (`SettingsLive` / Integrations). 

### Layout & Sections
The Google Drive integration card will be divided into three core sections:

1. **Target Selector (What to sync)**
   - Replaces the simple "Drive" toggles with a more hierarchical or granular list.
   - Shows currently selected targets:
     - 📁 **Engineering Team (Shared Drive)**
     - 📂 **Q3 Planning (Folder)**
     - 📄 **Architecture Revamp.md (File)**
   - **"Add Sync Target" Button:** Opens a modal with a file/folder picker to browse and connect new targets.

2. **Recently Synced (Activity Feed)**
   - A scrollable, lightweight list showing recently processed files.
   - Columns/Layout: File Icon | File Name | Sync Time | Status Badge
   - Statuses: `Synced` (Green), `Conflict` (Orange), `Error` (Red).

3. **Errors & Interventions**
   - Files in an `error` state bubble to the top of the "Recently Synced" list or a dedicated sub-section.
   - Shows the error reason (e.g., "Rate limited", "Unsupported format").
   - Action: **"Retry Now"** button next to errors.
   - Note: Retries happen automatically, but the manual button empowers users to unblock themselves.

## 2. Architecture & Data Model Changes

### Paradigm Shift: Local-First Agent Interaction
The primary purpose of syncing Google Drive files as Markdown/CSV formats is to create a fast, local sandbox for the agent. **The agent should never query the live Google Drive API for search.** It performs all file operations (reads, searches, modifications) locally within its synced context, and any local edits are pushed back to the upstream Drive as new revisions. 
*   **Deprecating Live Search:** Existing agent skills (`search.ex`) that query the live Drive API will be refactored to read local representations instead.
*   **Sandboxed Environment:** The `.synced_files` (or working directory) will act as the canonical source of truth for the agent while a task is running. Local changes will mark `sync_status` as `local_ahead` and queue an upstream sync.

### A. Granular Target Storage
Currently, we have `connected_drives`. To support folders and files, we should migrate this concept to a generic `sync_targets` (or `google_sync_targets`) table.

```elixir
# Proposed schema: Assistant.Schemas.SyncTarget
- user_id: binary_id
- target_type: string (enum: "drive", "folder", "file")
- target_id: string (Google Drive ID)
- target_name: string (For UI display without hitting API)
- enabled: boolean
```
*Note: The Drive Changes API (`ChangesApi.drive_changes_list`) can scope by Drive. For specific folders/files, we may need to filter the change feed, or rely on `FilesApi.drive_files_list` with a `q` parameter (e.g., `'folder_id' in parents`) for the initial sync, and filter the global change feed for subsequent updates.*

### B. Elixir / OTP Architecture & Resilience

The architecture strictly follows Elixir and BEAM best practices to guarantee resilience against rate limits, CPU-intensive document conversion, and multi-node concurrency conflicts.

1. **Concurrency and Backpressure (`Oban` vs `Task`)**
   - The `SyncPollWorker` handles only lightweight pagination cursors. When it detects changes, it does *not* process files synchronously inline. It bulk inserts (`Oban.insert_all`) into a new `FileSyncWorker` queue.
   - The `:google_drive_sync` Oban queue will have a strict concurrency limit (e.g., `5`) to prevent starving UI DB connections or hitting Google API rate limits (`429 Too Many Requests`).

2. **Event Sourcing & Decoupling**
   - The agent operates strictly on the local file system. When the agent finishes modifying a file, it updates the `StateStore` to `local_ahead` and broadcasts a `Phoenix.PubSub` event (`"file_sync:local_updated"`).
   - An isolated `UpstreamSyncWorker` listens for these events to asynchronously handle the slow networked API push, fully decoupling the fast chat response from network I/O.

3. **"Let it Crash" Conversion Pipeline**
   - The `Converter.ex` module heavily manipulates strings and HTML/Markdown ASTs. Instead of brittle `try/catch` wrapping for every edge case, the `FileSyncWorker` allows fatal formatting errors to crash the process. Oban will trap the exit, apply exponential backoff, and eventually mark the file as `error` after max retries (e.g., 7).

4. **Multi-Node Conflict Locking**
   - If the agent modifies `report.md` (triggering an upload) at the exact same time `SyncPollWorker` detects a remote change (triggering a download), we risk a split-brain. We will use database row-level locking via `Ecto.Multi` or `:global.trans` on the file's primary key to serialize writes.

5. **Streaming Large Files**
   - To prevent memory bloat and garbage collection spikes on the BEAM, large files (especially CSVs) retrieved from Google Drive will not be loaded into memory as complete binaries. We will use streaming (via `Req` and `File.stream!`) to write data straight to disk or pass them through `Stream` modifiers during conversion.

## 3. Implementation Plan

### Phase 1: Agent Sandbox Migration (Backend)
- [ ] Refactor existing agent skills (like `search.ex` and `archive.ex`) to operate against the local `synced_files` payload and local file system instead of calling `GoogleApi.Drive`.
- [ ] Establish the worker to handle `local_ahead` files, converting Markdown/CSV changes back to Google format and pushing them to the Drive API.

### Phase 2: Robust Worker Pipeline (Backend)
- [ ] Create `FileSyncWorker` to handle individual file downloads, conversion, and saving to `synced_files`.
- [ ] Refactor `SyncPollWorker` to enqueue `FileSyncWorker` jobs rather than processing files synchronously.
- [ ] Ensure `FileSyncWorker` correctly marks `sync_status = "error"` and updates `sync_error` text upon exhausting its Oban retries, while keeping intermediate failures in Oban's native retry loop.

### Phase 3: Granular Targets (Data Model)
- [ ] Create `sync_targets` table and schema to support drives, folders, and files.
- [ ] Write a data migration to move existing `connected_drives` records into `sync_targets`.
- [ ] Update cursor logic: We need to figure out the most efficient way to track changes for specific folders/files (likely tracking the global startPageToken for the user, and filtering the change stream by the parent IDs defined in `sync_targets`).

### Phase 4: The Target Picker UI (Frontend)
- [ ] Create a `SyncTargetBrowser` LiveComponent. This will act as an in-app file browser, calling `GoogleApi.Drive.V3.Api.Files.drive_files_list` to let the user navigate their Google Drive and check off folders or individual files.
- [ ] Update the Google Workspace integration card to list the defined `sync_targets` instead of just connected drives.

### Phase 5: Sync History & Retry UI (Frontend)
- [ ] Add the "Recently Synced" list to the Workspace integration card, querying the `synced_files` table partitioned by `user_id`, ordered by `last_synced_at DESC`.
- [ ] Add the manual "Retry" button. Clicking this enqueues a new `FileSyncWorker` job for that specific `drive_file_id` and sets the local state to `syncing`.
