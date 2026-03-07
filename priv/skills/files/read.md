---
name: "files.read"
description: "Read the content of a file from the synced workspace."
handler: "Assistant.Skills.Files.Read"
tags:
  - files
  - read
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

# files.read

Read the content of a file from the synced workspace. Files are identified
by their local workspace path (preferred) or by Drive file ID (resolved to
the local synced copy).

Content is truncated at 8,000 characters to protect LLM context budgets.

## Parameters

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| path | string | yes* | Local workspace path (e.g., "reports/q1-report.md") |
| id | string | yes* | Drive file ID — resolved to local path via synced files |

*One of `path` or `id` is required.

## Response

Returns the file content with a header:

```
## q1-report.md

This is the quarterly report for Q1 2026...
```

If the content exceeds 8,000 characters:

```
## q1-report.md

This is the quarterly report...

...content truncated at 8000 characters. Full file available in workspace.
```

## Usage Notes

- Use `--path` with the workspace-relative path (found via files.search).
- Use `--id` with a Drive file ID as a fallback — it resolves to the synced local copy.
- All content is read from the local encrypted workspace, not from Google Drive directly.
- The 8,000 character limit prevents large files from consuming too much LLM context.
