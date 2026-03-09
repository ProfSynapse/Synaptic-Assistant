# Implementation Plan: Provider-Neutral Storage Browser Foundation

> Created: 2026-03-09
> Status: IMPLEMENTING
> Direction: Keep provider-specific OAuth onboarding, but move file browsing and scoped selection onto a provider-neutral storage layer before Dropbox, Microsoft, or Box ship.

## Summary

This plan extends [the existing Dropbox + Microsoft OAuth-first plan](/Users/jrosenbaum/Documents/Code/Synaptic-Assistant/docs/plans/dropbox-microsoft-oauth-first-integration-plan.md) with a storage-browser foundation that is not Google-shaped.

The current Google Workspace Drive modal is tightly coupled to:

- Google Drive naming
- Google-only source assumptions
- Google-specific persisted tables
- Google-shaped LiveView assigns and events

That coupling is acceptable for a first pass, but it is the wrong foundation for:

- Dropbox namespace roots
- Microsoft OneDrive and SharePoint document libraries
- Box folder roots and mixed item lists

This implementation introduces provider-neutral storage concepts now, while the product is still in development and before additional providers depend on the current Google-only modal shape.

## Goals

1. Keep OAuth onboarding provider-specific.
2. Make source browsing and scoped selection provider-neutral.
3. Move the settings picker UI onto generic `Storage` and `FilePicker` abstractions.
4. Keep current Google behavior working while future-proofing for Dropbox, Microsoft, and Box.
5. Defer full sync-engine neutralization until non-Google sync actually ships.

## Design

### Provider Boundary

Add a new provider behaviour:

- `Assistant.Storage.Provider`

This behaviour defines:

- `list_sources/2`
- `search_sources/3`
- `get_source/3`
- `list_children/4`
- `get_delta_cursor/3`
- `normalize_file_kind/1`
- `capabilities/0`

The first concrete implementation is:

- `Assistant.Storage.Providers.GoogleDrive`

### Normalized Concepts

Introduce these provider-neutral concepts:

- `Assistant.Storage.Source`
  - top-level browsable root
  - examples: Google personal drive, Google shared drive, Dropbox namespace root, SharePoint library drive
- `Assistant.Storage.Node`
  - tree item inside a source
  - `node_type` is `:container | :file | :link`
- `connected_storage_sources`
  - persisted enabled/connected sources per user and provider
- `storage_scopes`
  - persisted include/exclude selections for source or node targets

### Google Compatibility

Google remains the first provider, but it should be treated as one adapter instead of the system shape.

Compatibility rules for this phase:

- New settings UI reads from provider-neutral storage tables.
- Google is the first provider adapter on the neutral picker contract.
- Legacy Google drive/scope UI paths are removed instead of mirrored.

## UI Refactor

Add reusable picker components:

- `AssistantWeb.Components.FilePicker`
  - source table and modal shell
- provider-specific wrapper copy stays outside the generic picker when needed

Picker state becomes provider-neutral:

- `file_picker_open`
- `file_picker_provider`
- `file_picker_mode`
- `file_picker_sources`
- `file_picker_selected_source`
- `file_picker_nodes`
- `file_picker_root_keys`
- `file_picker_expanded`
- `file_picker_loading`
- `file_picker_loading_nodes`
- `file_picker_error`
- `file_picker_selection_draft`
- `file_picker_dirty`
- `file_picker_continuations`

Picker events become provider-neutral:

- `open_file_picker`
- `close_file_picker`
- `select_file_picker_source`
- `expand_file_picker_node`
- `toggle_file_picker_node`
- `load_more_file_picker_children`
- `save_file_picker`

## Persistence

Add provider-neutral persistence now:

- `connected_storage_sources`
- `storage_scopes`

Do not add backfill or runtime mirroring from legacy Google tables in this phase.

## File Kinding

Keep one file-kind taxonomy for all providers:

- `doc`
- `sheet`
- `slides`
- `pdf`
- `image`
- `file`

The generic picker owns icon and badge rendering. Providers only normalize remote metadata into these buckets.

## Phase Split

### Phase 0

- provider-neutral storage domain
- provider-neutral persistence
- generic picker components
- Google adapted to the new picker flow

### Phase 1

- Dropbox OAuth + source discovery adapter

### Phase 2

- Microsoft OAuth + OneDrive / SharePoint source discovery adapter

### Phase 3

- provider routing across files, mail, and calendar

### Phase 4

- Box adapter if still desired

## Validation

This implementation should be considered complete for phase 0 when:

1. Google Workspace settings use the generic storage picker state and events.
2. Source and scope persistence go through the provider-neutral storage layer.
3. Legacy Google behavior still works.
4. Tests cover:
   - storage provider contracts
   - Google source discovery and child listing
   - storage scope persistence
   - settings picker regression behavior
