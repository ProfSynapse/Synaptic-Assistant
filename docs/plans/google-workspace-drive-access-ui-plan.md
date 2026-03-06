# Plan: Google Workspace Drive Access UX Consolidation

> Created: 2026-03-06
> Status: PROPOSED
> Scope: Product and UX plan only. No implementation in this document.

## Summary

The current Google Drive settings split the same concept across two labels:

- `Google Drive Access` for connecting drives
- `Sync Targets` for choosing which folders the agent actually ingests

That creates redundant mental models. A user does not care about "drive access" versus "sync target" as separate setup concepts. They care about one thing: **what content the assistant can access and keep in its workspace**.

This plan moves Drive access management into the existing Google Workspace app detail page at `/settings/apps/google_workspace`, replaces the split model with a single scoped-access surface, and defines the downstream sync behavior when access is granted or revoked.

## Problems To Solve

1. The current UI lives in the broad Apps page instead of inside the Google Workspace detail page where users already connect Google.
2. `Drive Access` and `Sync Targets` are separate labels for nearly the same user intent.
3. The current flow is optimized for folder sync, but the product now needs three levels:
   - full drive
   - specific folder
   - specific file
4. The common case should be fast:
   - grant a whole drive
   - grant one folder
5. The rare case should still exist:
   - drill down to a specific file
6. Access changes must cascade into the agent workspace:
   - granting access should sync/import content
   - revoking access should remove converted files that are no longer covered

## Product Principles

1. Treat sync as a consequence of access, not a separate setup flow.
2. Optimize for the 80% case:
   - full drive
   - folder
3. Make file-level targeting available, but intentionally deeper.
4. Keep destructive actions obvious and reversible where possible.
5. Show status in the same place the access decision is made.
6. Avoid button clutter by using progressive disclosure instead of exposing every action inline.

## Proposed Information Architecture

### Placement

Move the Drive management experience into the existing Google Workspace app detail page:

- page: `/settings/apps/google_workspace`
- current host component: `lib/assistant_web/components/settings_page/app_detail.ex`

This is the right surface because it already owns:

- Google account connection state
- Google-specific setup guidance
- integration-specific configuration

The Apps overview page should keep only the card/catalog view and stop being the place where Drive scoping is managed.

### Replace The Current Two-Section Model

Replace:

- `Google Drive Access`
- `Sync Targets`

With one primary configuration section:

- `Available Drives`

That section should answer three questions in one place:

1. Which drives are available?
2. What level of access has been granted for each drive?
3. What is currently synced into the agent workspace as a result?

## Proposed UX Model

### Top-Level Page Structure

Inside the Google Workspace detail page:

1. `Connection`
   - Connect / disconnect Google account
   - Show connected email
2. `Available Drives`
   - Table of drives with a full-access toggle and a manage button
3. `Recent Sync Activity`
   - Operational status only

The key change is that the main control surface is a **drive table**, not a card-per-target or a separate sync-target picker.

## Core Interaction Model

### 1. Drive Table Is The Main Surface

The Google Workspace page should open into a simple table:

- drive name
- drive type
- full access toggle
- manage button
- optional status summary

This keeps the broad access decision very fast:

- toggle on for full drive access
- click manage only when granular access is needed

### 2. Full Access Toggle Is The Default Fast Path

Each drive row gets a `Full Access` toggle.

Behavior:

- toggle `on` means everything in the drive is allowed
- toggle `off` means the drive is no longer globally allowed and granular rules may apply

This is the primary interaction because it matches the common case you called out.

### 3. Manage Opens A Dedicated Modal

The `Manage` action should open a dedicated modal for that specific drive.

This should not expand inline beneath the table row. The inline approach makes the page feel heavy, breaks the table rhythm, and causes the file tree to visually spill out into the rest of the settings page.

The manage modal should render:

- a header with the drive name
- a short summary of what the user is doing
- the scoped-access tree
- sticky footer actions:
  - `Cancel`
  - `Save Access`

This gives one strong mental model:

- full drive access from the table
- folder/file access inside a focused, dedicated browser surface

### 4. Folder Rows Support Selection And Traversal

For each folder row:

- use the existing folder open/closed icons to communicate state
- the checkbox controls selection
- the rest of the row controls expand/collapse
- checking the folder selects the whole subtree
- unchecking the folder clears the whole subtree unless specific children are selected again
- indeterminate `-` means only part of the subtree is selected
- the user can open the folder at any time to inspect or edit child selections

There should not be a separate chevron if the row itself already communicates expand/collapse through the folder icon and row hover state.

There are therefore two interactions on a folder row:

- checkbox click = selection
- row click = expand/collapse

This is still adjacent to an existing pattern already used elsewhere in the codebase:

- the accordion shell and open/close behavior already exist
- see `lib/assistant_web/live/workflow_editor_live.ex`

But the final surface should feel more like a modern permission browser than a literal accordion list.

### 5. Nested Selection Rules

Inside an expanded folder row:

- subfolders have checkboxes
- files have checkboxes
- subfolders use folder icons
- files use file icons, ideally aligned to file type when known
- checking a subfolder selects every file in that subfolder
- unchecking one or more children makes the parent subfolder show an indeterminate `-` state
- every subfolder can also be expanded so the user can keep traversing deeper

This makes the hierarchy behave like a normal file-permissions tree:

- fully checked = everything below is allowed
- empty = nothing below is allowed
- indeterminate = partial access below

### 6. Granular File Access Is Only Visible After Drilldown

The manage modal should not dump the whole file tree immediately.

Recommended behavior:

- show top-level folders first
- only show subfolders/files when a folder row is opened
- keep file-level checkboxes inside the opened hierarchy
- allow recursive traversal through all subfolders

That keeps the drive table compact while still supporting specific-file access in the modal.

## Recommended UI Shape

### Available Drives Table

The drive table should include:

- `Drive`
- `Type`
- `Full Access`
- `Details`
- `Status`

Example row behavior:

- if `Full Access` is on, status can say `All content allowed`
- if `Full Access` is off but granular selections exist, status can say `Granular access configured`
- if no access exists, status can say `No access`

### Manage Modal Structure

The details column should use a compact icon button rather than repeating a `Manage` text button in every row.

Recommended pattern:

- column header can be blank or use a subtle label like `Details`
- row action uses a single icon button
- good icon candidates:
  - sliders
  - chevron/expand
  - settings/cog if it does not conflict with the top-level app settings meaning

Clicking that icon button should open a drive-specific management modal.

That modal should contain:

- a short explanatory header
- optional selection summary
- the file tree
- sticky footer actions

It should read like a focused file-permissions browser, not like a settings accordion embedded inside the page.

### Folder Row Rules

Each folder summary row should contain:

- selection checkbox
- folder icon
- folder name
- optional selection summary

Rules:

- closed folders use the closed-folder icon
- open folders use the open-folder icon
- clicking the row opens/closes the folder
- expanding the row reveals the child tree
- collapsing the row hides the child tree
- checked row = entire subtree allowed
- unchecked row = subtree not allowed unless descendants are checked
- indeterminate row = partial descendant selection
- if child tree has partial selection, show a subtle summary like `3 of 12 items allowed`
- checkbox click must not toggle expand/collapse

### Checkbox Tree Rules

Within the expanded child area:

- subfolders render with folder icons
- files render with file icons
- subfolder checkbox selects all descendants
- file checkbox selects only that file
- partial child selection makes the parent visually indeterminate
- subfolders open when the user clicks their row

This is where file-level access lives. It should not compete with the simpler drive-level full access control.

### Tree Row Anatomy

Each selectable row should look like:

- checkbox
- type icon
- label

Examples:

- `[-] [folder-open] Launch Materials`
- `[ ] [folder] Assets`
- `[x] [doc] Plan`
- `[ ] [pdf] Passwords`

This should be the canonical tree pattern for the feature.

Checkboxes should be visually real and explicit:

- `[ ] [icon] Title`
- `[x] [icon] Title`
- `[-] [icon] Title`

This is important because the current interaction can feel ambiguous if the selected state is communicated only through custom boxes or row tinting.

## Visual Design Spec

The current functionality is correct, but the file tree still feels like a raw filesystem dump. The updated visual spec should aim for a more modern permission-browser feel.

### Design Goals

1. Make the tree feel intentional and interactive, not like plain indented text.
2. Make hierarchy readable without relying only on indentation.
3. Make selection feel obvious and high-confidence.
4. Make the modal feel like a dedicated browser surface rather than a generic settings dialog.
5. Let the drive table and personal tool access sections use the full available page width.

### Drive Table Width

The `Available Drives` table should take the full width of the content area.

Recommended behavior:

- table stretches to the full card width
- `Drive` column gets the majority of the width
- `Scope` column gets flexible middle width
- `Full Access` stays compact
- action column stays tight

This should avoid the current cramped feel where the table occupies only part of the page and leaves too much empty space to the right.

### Personal Tool Access Width

`Personal Tool Access` should also stretch across the full content width.

Recommended behavior:

- use a full-width table or grouped rows
- avoid narrow columns with excessive wrapping
- give the `Skill` label room to breathe
- keep the toggle column compact and aligned right

This section should feel like a peer to the drive table, not like a squeezed secondary control.

### Modal Proportions

The drive manage modal should feel more like a browser panel than a small dialog.

Recommended proportions:

- width: approximately `min(1100px, calc(100vw - 64px))`
- height cap: approximately `80vh` to `85vh`
- sticky header
- sticky footer
- scrolling only in the tree content region

### File Tree Visual Treatment

Each item should be rendered as a full-width row block, not as loose inline text.

Recommended row anatomy:

- checkbox
- icon
- label
- optional trailing metadata

Recommended row styling:

- row hover state
- subtle selected background tint
- rounded row container
- slightly larger row height than the current implementation

### Hierarchy Treatment

Hierarchy should be visible through more than indentation.

Recommended techniques:

- soft inset container for children when a folder is open
- faint left guide or rail for nested content
- stronger visual treatment for folders than files
- consistent spacing between top-level rows

This will make the tree easier to scan and prevent the current “wall of filenames” feeling.

### Folder Row Behavior

Folders should feel like expandable sections inside a permission browser.

Recommended styling:

- closed folder icon
- open folder icon
- row hover state
- row click target across the full row except the checkbox

Folders should not need a separate chevron if:

- the icon changes state clearly
- the row hover/click affordance is strong

### File Row Behavior

Files should feel quieter than folders but still interactive.

Recommended styling:

- smaller visual emphasis than folders
- type-specific icon or badge
- selected state uses row tint plus checkbox state
- long filenames truncate cleanly with ellipsis

### Selection Feedback

Selection should be visible in multiple ways, not just the checkbox box itself.

Recommended techniques:

- checkbox state
- subtle selected-row background tint
- optional trailing chip like `Included` only when useful
- indeterminate rows use a distinct mixed-state treatment

### Density

The tree should feel modern and breathable, not cramped.

Recommended baseline:

- row height around `40px` to `44px`
- slightly larger spacing between top-level nodes
- smaller but still comfortable spacing for nested nodes

### Footer Actions

The modal footer should stay visible and actionable.

Recommended footer behavior:

- sticky footer
- `Cancel` on the left
- `Save Access` on the right
- disabled save state when there are no changes
- optional dirty-state text like `Unsaved changes`

## Modern File Tree Pattern

The target pattern should feel closer to a modern permission browser used in cloud tools than to a raw Finder/Explorer dump.

### Recommended Mental Model

This should feel like:

- a scoped access browser
- a selective sync picker
- a permissions tree

It should not feel like:

- a raw shell listing
- a plain indented document outline
- a settings accordion with checkboxes bolted on

### Recommended Visual Example

```text
[ ] [folder] Launch Materials                               12 items
    [ ] [folder] Assets
    [x] [doc] Plan
    [-] [folder-open] SOPs
        [x] [pdf] Setup Guide
        [ ] [image] Diagram
```

Visually, however, each line should really behave as a full row block with hover, spacing, and selected state, not as monospaced plain text.

### File Icon Rules

When file metadata is available, use type-specific icons so the tree is easier to scan:

- Google Doc -> document icon
- Google Sheet -> spreadsheet/table icon
- Google Slides -> presentation icon
- PDF -> PDF/document icon
- image files -> image icon
- unknown binary -> generic file icon

If the exact type is not yet known in the browser response, fall back to the generic file icon rather than delaying rendering.

Recommended distinction:

- Google Workspace types get product-specific icons
- non-Workspace assets get file-type icons where possible
- fallback stays generic if type metadata is missing or unsupported

## Shared Pattern Reuse

Reuse existing codebase patterns as much as possible.

### Best Existing Match

The best existing interaction match is the workflow editor accordion shell:

- `sa-accordion`
- `AccordionControl`

Reference:

- `lib/assistant_web/live/workflow_editor_live.ex`

We should reuse the general open/close control patterns and modal structure where useful, but the final Drive browser should not be constrained to look like a generic accordion.

### Other Existing Patterns To Reuse

For the top-level table and checkbox styling, existing settings/admin surfaces should be reused where possible instead of building new bespoke controls:

- `lib/assistant_web/components/settings_page/admin.ex`
- `lib/assistant_web/components/settings_page/app_detail.ex`
- `lib/assistant_web/components/settings_page/apps.ex`

For icons, reuse the existing shared icon component rather than introducing custom asset logic.

If type-specific file icons are added, they should still flow through the same shared icon component/API rather than creating a one-off rendering path just for Drive.

### Pattern Gap

I did not find an existing tri-state checkbox tree component in the current codebase.

So the likely reuse plan is:

- reuse the accordion behavior directly
- reuse existing checkbox/table styling patterns
- add a recursive tree layer with indeterminate states for folder/subfolder checkboxes

## Non-Text Assets

This is slightly outside the immediate drive-access UI scope, but it should be captured in the plan now because it affects:

- iconography in the manage tree
- sync/storage behavior
- which files can be sent to the LLM at runtime

### Current Direction

Drive access should not be limited to text-like Google Workspace files.

The plan should explicitly support these additional asset classes:

- PDFs
- images

At the access-management level, they should be selectable exactly like Docs/Sheets/Slides.

### Sync Direction

PDFs and images should still be synced into the agent workspace when allowed by the drive/folder/file rules.

Recommended support tiers:

- Google Docs / Sheets / Slides:
  - synced
  - converted into agent-friendly formats
  - searchable/indexable
- PDFs:
  - synced as binary/document assets
  - available for direct LLM attachment when the selected model supports document ingestion
  - text extraction/indexing can be treated as a later enhancement
- Images:
  - synced as binary/image assets
  - available for direct LLM attachment when the selected model supports image ingestion
  - OCR/indexing can be treated as a later enhancement

This keeps the access UI simple while acknowledging different downstream handling.

### Storage Direction

The current architecture can already store raw binary content in Postgres via the encrypted `content` field on synced files.

So the plan should assume:

- PDFs can be stored
- images can be stored
- both can be removed on revoke just like converted markdown/csv files

Follow-up implementation work should correct format handling so these assets are represented honestly as binary/document/image assets instead of pretending to be plain text.

### Model Capability Gating

Only models that can actually ingest the relevant asset type should receive those synced files.

Recommended rule:

- text-only models receive text-like synced files only
- document-capable models may receive PDFs
- vision-capable models may receive images
- multimodal models may receive both PDFs and images when supported

This should be enforced by capability checks in the model-selection/runtime layer rather than by hiding the files from sync.

In other words:

- sync eligibility is controlled by drive access rules
- attachment eligibility is controlled by model capabilities

### UI Implication

The manage tree should visually distinguish these asset types so users understand what they are granting:

- `[doc]`
- `[sheet]`
- `[slides]`
- `[pdf]`
- `[image]`
- generic fallback for unknown files

That is especially important once PDFs/images are allowed, because otherwise the tree makes everything look like interchangeable files.

## Access Flows

### Flow A: Full Drive Access

1. User opens the Google Workspace detail page
2. User sees the drive table
3. User toggles `Full Access` on for a drive
4. System marks the drive as fully allowed
5. Initial sync is queued

This should be one action from the main table.

### Flow B: Folder Access

1. User leaves `Full Access` off
2. User clicks the row details icon
3. A modal opens for that drive
4. User sees top-level folder rows
5. User checks a folder row
6. User clicks `Save Access`
7. System treats the whole subtree as allowed
8. Sync is queued for that folder

This should be the fastest granular path.

### Flow C: Specific Files In A Folder

1. User leaves `Full Access` off
2. User clicks the row details icon
3. A modal opens for that drive
4. User finds the folder
5. User expands the folder by clicking the row
6. User checks subfolders and/or files
7. User continues traversing deeper subfolders as needed
8. Parent rows become indeterminate when only some children are selected
9. User clicks `Save Access`

This keeps specific-file access available without adding more primary buttons, including for PDFs and images.

## Revoke / Reduce Access Flows

### Revoke Full Drive

1. User turns `Full Access` off in the drive table
2. If no granular rules exist, access is removed completely
3. If granular rules do exist, the drive remains partially accessible through manage selections

### Revoke Folder

1. User opens the drive manage modal
2. User unchecks a folder row
3. The subtree is deselected unless specific children are reselected
4. User clicks `Save Access`
5. User can either:
   - leave everything unchecked to remove all folder access
   - check only the specific subfolders/files that should remain allowed

### Revoke Specific Files

1. User opens the manage modal
2. User unchecks one or more files
3. Parent subfolder/folder shifts to indeterminate if only part of it remains allowed
4. User clicks `Save Access`

This keeps reduction of access in the same place access was granted.

## Sync And Workspace Cascade Rules

This is the most important product rule behind the UI:

### Granting Access

When access is granted:

1. Persist the grant
2. Queue initial discovery/sync for the target
3. Show target state as:
   - `Pending sync`
   - then `Synced`
   - or `Error`
4. Create or update converted markdown/csv/etc. files in the agent workspace

For PDFs/images, "sync" means storing the allowed asset and making it available for later model attachment even if it is not yet text-indexed.

### Revoking Access

When access is revoked:

1. Persist the revoke first
2. Cancel or ignore future sync jobs for content that is no longer allowed
3. Remove converted files from the agent workspace for content no longer covered
4. Remove related synced-file records only when no remaining access grant still includes them

### Overlap Rule

This must be explicit in the implementation plan:

- if a file is covered by both a full-drive grant and a folder grant, revoking the folder grant must not remove the file
- if a file is covered only by the revoked grant, it should be removed from the agent workspace

The UI should communicate this in simple language:

- `Items still covered by another access rule will stay synced.`

## Data Model Direction

### Keep Two Technical Layers, But One User Concept

Internally, it is still valid to distinguish:

1. drive connection/discovery
2. allowed content targets

But the UI should not present them as peer setup systems.

### Recommended Terminology

Avoid user-facing labels like:

- `Sync Targets`
- `Scopes`

Prefer:

- `Available Drives`
- `Details`
- `Allowed Content`
- `Synced from this access`

### Recommended Model Direction

Current backend shape:

- `connected_drives`
- `sync_scopes`

Recommended future direction:

- keep `connected_drives` for connection/discovery state
- evolve `sync_scopes` into a more general access-target model that can represent:
  - drive
  - folder
  - file

Suggested conceptual rename:

- `drive_access_targets`

Each target should eventually capture:

- `target_type`: drive | folder | file
- `target_id`
- `target_name`
- `target_mime_type` or equivalent file-type metadata for icon/runtime decisions
- `drive_id`
- `parent_target_id` or ancestry info if needed
- sync/access status fields for UI

## Model Capability Follow-Up

Because the plan now includes PDFs and images, implementation should include a small capability model for attachments.

Minimum capability categories:

- `text_ingest`
- `document_ingest`
- `image_ingest`

Recommended behavior:

- only expose PDF/image attachments to models with the matching capability
- if a conversation/model cannot ingest an allowed asset, keep the asset synced but do not attach it
- when useful, show a subtle product message like `Some synced files require a multimodal model to use`

## Sync Status Surface

The page should show sync outcome without reintroducing another setup flow.

Recommended items:

- last sync time per drive
- pending sync count
- recent failures
- recent imports/removals

This can live below `Available Drives` as:

- `Recent Sync Activity`

Not:

- a second target-selection area

## Suggested Wireframe

```text
Google Workspace
Connected as user@company.com

[ Available Drives ]

| Drive                    | Type       | Full Access | Details  | Status              |
|--------------------------|------------|-------------|----------|---------------------|
| My Drive                 | Personal   | ON          |   [=]    | All content allowed |
| Brand Studio             | Shared     | OFF         |   [=]    | Granular access     |
| Legal                    | Shared     | OFF         |   [=]    | No access           |

[ Recent Sync Activity ]
- Q1 Plan synced 2m ago
- Campaigns queued for sync
- Roadmap.md removed after access revoked
```

## ASCII Diagrams

### Updated Direction

The diagrams below are superseded by the more specific visual rules in `Visual Design Spec` and `Modern File Tree Pattern`.

The final direction should assume:

- full-width drive table
- full-width personal tool access section
- drive-specific manage modal
- row-click folder expansion
- explicit checkboxes
- sticky modal footer with save action

### 1. Apps Overview

The Apps overview keeps Google Workspace as a card entry point only.

```text
+---------------------------------------------------------------+
| Apps & Connections                                            |
+---------------------------------------------------------------+
|                                                               |
|  +--------------------+   +--------------------+              |
|  | Google Workspace   |   | Telegram           |              |
|  | Gmail, Calendar,   |   | Bot messages       |              |
|  | Drive              |   |                    |              |
|  |                    |   |                    |              |
|  | [Open]             |   | [Open]             |              |
|  +--------------------+   +--------------------+              |
|                                                               |
|  Open Google Workspace to manage Drive access.                |
|                                                               |
+---------------------------------------------------------------+
```

### 2. Google Workspace Page

```text
+----------------------------------------------------------------------------+
| <- Back   Google Workspace                                                 |
|           Connect approved Google tools for email, calendars, docs.        |
+----------------------------------------------------------------------------+
| Connection                                                                 |
| Connected as user@company.com                               [Disconnect]    |
+----------------------------------------------------------------------------+
| Available Drives                                                           |
|                                                                            |
| | Drive                    | Type     | Full Access |   []   | Status     | |
| |--------------------------|----------|-------------|--------|------------| |
| | My Drive                 | Personal |    ON       |  [=]   | All access | |
| | Brand Studio             | Shared   |    OFF      |  [=]   | Granular   | |
| | Legal                    | Shared   |    OFF      |  [=]   | No access  | |
|                                                                            |
+----------------------------------------------------------------------------+
| Recent Sync Activity                                                       |
| Q1 Plan synced 2m ago                                                      |
| Campaigns queued for sync                                                  |
| Roadmap.md removed after access revoked                                    |
+----------------------------------------------------------------------------+
```

### 3. Manage View For A Drive

Clicking the row details icon expands a drive-specific section below the row.

```text
+----------------------------------------------------------------------------+
| Brand Studio                                         Full Access: [OFF]    |
| Granular access configured                                              ^  |
+----------------------------------------------------------------------------+
|                                                                            |
| [x] > [folder] Campaigns                                                   |
| [-] > [folder] Sales Collateral                                            |
| [ ] > [folder] Product Launch                                              |
+----------------------------------------------------------------------------+
```

### 4. Selected Folder Row

When a folder row is checked, the whole subtree is allowed. It can still be opened later if the user wants to inspect children.

```text
+----------------------------------------------------------------------------+
| [x] > [folder] Campaigns                                                   |
|   Entire folder allowed                                                   |
+----------------------------------------------------------------------------+
```

### 5. Expanded Folder With Granular Selection

An expanded folder row shows immediate children. Selection state is carried by the checkbox, and traversal is carried by the chevron.

```text
+----------------------------------------------------------------------------+
| [-] v [folder-open] Sales Collateral                                       |
|                                                                            |
|   [x] > [folder] Brand Assets                                              |
|   [-] v [folder-open] Launch Materials                                     |
|   [ ] > [folder] Archive                                                   |
|   [x] [sheet] pricing-sheet                                                |
|   [ ] [doc] legal-notes                                                    |
|   [x] [slides] logo-guidelines                                             |
|   [x] [pdf] pricing-overview.pdf                                           |
|   [ ] [image] packaging-mockup.png                                         |
+----------------------------------------------------------------------------+
```

### 6. Subfolder Selection Rules

Checking a subfolder selects everything below it. Partial child selection makes the parent indeterminate.

```text
+----------------------------------------------------------------------------+
| [-] v [folder-open] Launch Materials                                       |
|                                                                            |
|   [ ] > [folder] Assets                                                    |
|   [x] [doc] Plan                                                           |
|   [ ] [pdf] Passwords                                                      |
+----------------------------------------------------------------------------+
```

### 6A. Folder Interaction Sequence

This is the intended sequence for a folder where the user wants file-level control:

```text
STEP 1: folder row starts collapsed

| [ ] > [folder] Sales Collateral                          |

STEP 2: user clicks expand control

| [-] v [folder-open] Sales Collateral                     |
|   [ ] > [folder] Assets                                  |
|   [x] [doc] Plan                                         |
|   [ ] [pdf] Passwords                                    |

STEP 3: user expands Assets and keeps traversing as deep as needed

| [-] v [folder-open] Sales Collateral                     |
|   [-] v [folder-open] Assets                             |
|     [x] [image] hero.png                                 |
|     [ ] [image] thumbnail.jpg                            |
|   [x] [doc] Plan                                         |
|   [ ] [pdf] Passwords                                    |
```

### 7. Full Drive Toggle Interaction

The drive table is optimized so broad access is a one-step action.

```text
BEFORE
| Legal | Shared | OFF | [=] | No access |

USER TOGGLES FULL ACCESS ON

AFTER
| Legal | Shared | ON  | [=] | All content allowed |
```

### 8. Revoke Messaging

The UI should explain the sync cascade at the moment access is reduced.

```text
+------------------------------------------------------------------+
| Access Updated                                                   |
|                                                                  |
| Content no longer covered by this drive/folder selection will    |
| be removed from the agent workspace unless another rule still    |
| allows it.                                                       |
+------------------------------------------------------------------+
```

## Phased Plan

### Phase 1: UX Consolidation

1. Move Drive content management into the Google Workspace detail page.
2. Remove the separate `Sync Targets` framing from the Apps overview.
3. Introduce the `Available Drives` table with `Full Access` and an icon-only details action column.

### Phase 2: Granular Manage View

1. Add the per-drive manage panel beneath the selected drive row.
2. Render top-level folders as recursive tree rows inside accordions.
3. Reuse the workflow editor accordion shell and existing checkbox styling where possible.

### Phase 3: Nested Selection Tree

1. Add nested subfolder and file checkboxes inside open accordions.
2. Support parent-folder select-all behavior for descendants.
3. Add indeterminate `-` states for partially selected subfolders/folders.

### Phase 4: Cascade Enforcement And Activity

1. Make drive/folder/file selections the source of truth for sync eligibility.
2. On revoke, remove converted workspace files that are no longer covered.
3. Preserve files still covered by overlapping grants.
4. Show queued/synced/error/removed states in recent activity.

### Phase 5: Asset-Aware Runtime Support

1. Add PDF/image icon treatment to the manage tree.
2. Ensure PDFs/images are stored as synced assets in Postgres.
3. Gate PDF/image attachment to the LLM on model capabilities.
4. Keep text extraction/OCR as a separate later enhancement rather than a blocker for sync support.

## Implementation Notes For Later

When implementation starts, the first pass should likely touch:

- `lib/assistant_web/components/settings_page/app_detail.ex`
- `lib/assistant_web/components/drive_settings.ex`
- `lib/assistant_web/components/sync_target_browser.ex`
- `lib/assistant_web/live/settings_live/loaders.ex`
- `lib/assistant_web/live/settings_live/events.ex`
- sync state/storage modules that currently assume folder-only scope

The expected UI relocation is:

- out of the generic Apps overview
- into the existing Google Workspace detail page

## Open Questions

1. Should `My Drive` appear as a pseudo-drive card even before Google returns shared drives, so the broad personal-drive case stays obvious?
2. Should file-level access allow multi-select in one pass, or stay one-at-a-time for simplicity in v1?
3. Should revoked items appear temporarily in recent activity as `Removed from workspace` so users can see the cascade happened?
4. Do we want a distinction between `searchable` and `synced locally`, or should all allowed content be synced automatically with no separate mode?

## Recommendation

Proceed with a single user concept:

- **Grant access to content**

And treat sync as the automatic downstream effect of that decision.

That gives the simplest mental model, matches the actual product behavior, and makes it easier to support drive, folder, and file access without filling the page with separate buttons and parallel configuration lists.
