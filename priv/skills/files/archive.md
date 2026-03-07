---
name: "files.archive"
description: "Archive a file from the synced workspace."
handler: "Assistant.Skills.Files.Archive"
requires_approval: true
tags:
  - files
  - archive
  - workspace
parameters:
  - name: "path"
    type: "string"
    required: false
    description: "Local workspace path (e.g., \"reports/q1-report.md\")"
  - name: "id"
    type: "string"
    required: false
    description: "Drive file ID — resolved to local path via synced files"
---

# files.archive

Archive a file from the synced workspace. The file's local content is removed
and the file is trashed in Google Drive asynchronously.

## Parameters

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| path | string | yes* | Local workspace path (e.g., "reports/q1-report.md") |
| id | string | yes* | Drive file ID — resolved to local path via synced files |

*One of `path` or `id` is required.

## Response

Returns confirmation that the file was archived:

```
Archived 'quarterly-report.md'. It will be trashed in Google Drive shortly.
```

## Usage Notes

- Use `--path` with the workspace-relative path (found via files.search).
- Use `--id` with a Drive file ID as a fallback — it resolves to the synced local copy.
- The file's local content is cleared immediately (soft delete).
- The file is trashed in Google Drive asynchronously via the upstream sync worker.
- This action requires approval before execution.
