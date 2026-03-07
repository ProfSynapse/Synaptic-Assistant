---
name: "files.search"
description: "Search synced workspace files by name, type, and folder."
handler: "Assistant.Skills.Files.Search"
tags:
  - files
  - read
  - search
  - workspace
parameters:
  - name: "query"
    type: "string"
    required: false
    description: "Search text matched against file names and paths"
  - name: "type"
    type: "string"
    required: false
    description: "File type filter: \"doc\", \"sheet\", \"slides\", \"pdf\", \"folder\", \"image\", \"video\""
  - name: "folder"
    type: "string"
    required: false
    description: "Folder path segment to scope the search"
  - name: "limit"
    type: "integer"
    required: false
    description: "Max results to return (default 20, max 100)"
---

# files.search

Search synced workspace files matching a text query, type filter, and/or
folder scope. Results are sorted by most recently synced. All queries run
against the local database — no Drive API calls are made.

## Parameters

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| query | string | no | Search text matched against file names and local paths |
| type | string | no | File type filter: "doc", "sheet", "slides", "pdf", "folder", "image", "video" |
| folder | string | no | Folder path segment to scope the search |
| limit | integer | no | Max results to return (default 20, max 100) |

## Response

Returns a formatted list:

```
Found 3 file(s):
- [drive-id-1] Q1 Report (Google Doc) | Local Path: reports/q1-report.md | Last Synced: 2026-02-15 14:30
- [drive-id-2] Budget 2026 (Google Sheet) | Local Path: finance/budget-2026.csv | Last Synced: 2026-02-10 09:15
- [drive-id-3] Presentation.pdf (PDF) | Local Path: decks/presentation.pdf | Last Synced: 2026-01-28 16:45
```

Returns "No files found matching the given criteria." when no results match.

## Usage Notes

- All parameters are optional; calling with no parameters returns the 20 most recently synced files.
- The `type` filter maps to original Drive MIME types (e.g., "doc" = Google Docs, "sheet" = Google Sheets).
- The `folder` parameter matches against the local workspace path (e.g., "reports" matches files in "reports/").
- Files with `error` sync status are excluded.
- Results include Drive file ID, name, type, local path, and last sync time.
