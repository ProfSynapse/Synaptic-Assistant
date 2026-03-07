---
name: "files.write"
description: "Write content to a file in the synced workspace."
handler: "Assistant.Skills.Files.Write"
tags:
  - files
  - write
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
  - name: "content"
    type: "string"
    required: true
    description: "The text content to write"
---

# files.write

Write content to a file in the synced workspace. The file is identified by its
local workspace path (preferred) or by Drive file ID (resolved to the local
synced copy). Changes are written locally and synced back to Drive asynchronously.

## Parameters

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| path | string | yes* | Local workspace path (e.g., "reports/q1-report.md") |
| id | string | yes* | Drive file ID — resolved to local path via synced files |
| content | string | yes | The text content to write |

*One of `path` or `id` is required.

## Response

Returns confirmation with the file details:

```
File updated successfully.
Name: meeting-notes.md
Path: notes/meeting-notes.md
```

## Usage Notes

- Use `--path` with the workspace-relative path (found via files.search).
- Use `--id` with a Drive file ID as a fallback — it resolves to the synced local copy.
- The file must already exist in the synced workspace (use files.search to find it).
- Changes are written locally first, then pushed to Google Drive asynchronously.
- This overwrites the full file content — use files.update for targeted replacements.
