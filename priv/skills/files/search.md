---
name: "files.search"
description: "Search Google Drive files by name, type, and folder."
handler: "Assistant.Skills.Files.Search"
tags:
  - files
  - read
  - search
  - drive
---

# files.search

Search Google Drive for files matching a text query, MIME type filter, and/or
folder scope. Results are sorted by most recently modified. The service account
must have access to the files (shared drives are supported).

## Parameters

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| query | string | no | Search text matched against file names |
| type | string | no | File type filter: "doc", "sheet", "slides", "pdf", "folder", "image", "video" |
| folder | string | no | Parent folder ID to scope the search |
| limit | integer | no | Max results to return (default 20, max 100) |

## Response

Returns a formatted list:

```
Found 3 file(s):
- [1a2b3c] Q1 Report (Google Doc) | Modified: 2026-02-15 14:30 | Size: 12.5 KB
- [4d5e6f] Budget 2026 (Google Sheet) | Modified: 2026-02-10 09:15
- [7g8h9i] Presentation.pdf (PDF) | Modified: 2026-01-28 16:45 | Size: 2.3 MB
```

Returns "No files found matching the given criteria." when no results match.

## Usage Notes

- All parameters are optional; calling with no parameters returns the 20 most recently modified files.
- The `type` filter maps to Google Drive MIME types (e.g., "doc" = Google Docs, "sheet" = Google Sheets).
- The `folder` parameter accepts a Drive folder ID (not a folder name).
- Trashed files are excluded by default.
- Results include file ID, name, type, modification date, and file size (when available).
