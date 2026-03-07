---
name: "files.update"
description: "Update a workspace file's content by replacing text."
handler: "Assistant.Skills.Files.Update"
tags:
  - files
  - update
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
  - name: "search"
    type: "string"
    required: true
    description: "Text to find in the file"
  - name: "replace"
    type: "string"
    required: true
    description: "Replacement text (use \"\" for deletion)"
  - name: "all"
    type: "flag"
    required: false
    description: "Replace all occurrences (default: replace first only)"
---

# files.update

Update a workspace file's content by finding and replacing text. Works like
`sed -i 's/old/new/'` — reads the local file, applies the replacement, and
writes the result back. Changes are synced to Drive asynchronously.

## Parameters

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| path | string | yes* | Local workspace path (e.g., "reports/q1-report.md") |
| id | string | yes* | Drive file ID — resolved to local path via synced files |
| search | string | yes | Text to find in the file |
| replace | string | yes | Replacement text (use "" for deletion) |
| all | flag | no | Replace all occurrences (default: replace first only) |

*One of `path` or `id` is required.

## Response

Returns a summary of changes made:

```
Updated meeting-notes.md: replaced 2 occurrence(s) of 'draft'.
```

If the search text is not found:

```
No changes made (pattern not found).
```

## Usage Notes

- Use `--path` with the workspace-relative path (found via files.search).
- Use `--id` with a Drive file ID as a fallback — it resolves to the synced local copy.
- By default, only the first occurrence of `--search` is replaced. Use `--all` to replace every occurrence.
- The `--replace` parameter accepts an empty string to delete matched text.
- Changes are written locally first, then pushed to Google Drive asynchronously.
