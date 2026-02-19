---
name: "files.update"
description: "Update a Google Drive file's content by replacing text."
handler: "Assistant.Skills.Files.Update"
tags:
  - files
  - update
  - drive
---

# files.update

Update a Google Drive file's content by finding and replacing text. Works like
`sed -i 's/old/new/'` — reads the file, applies the replacement, and writes
the result back.

## Parameters

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| id | string | yes | The Google Drive file ID to update |
| search | string | yes | Text to find in the file |
| replace | string | yes | Replacement text (use "" for deletion) |
| all | flag | no | Replace all occurrences (default: replace first only) |

## Response

Returns a summary of changes made:

```
Updated meeting-notes.txt: replaced 2 occurrence(s) of 'draft'.
```

If the search text is not found:

```
No changes made (pattern not found).
```

## Usage Notes

- The `id` parameter is the Google Drive file ID (found via files.search or from a Drive URL).
- By default, only the first occurrence of `--search` is replaced. Use `--all` to replace every occurrence.
- The `--replace` parameter accepts an empty string to delete matched text.
- Google Workspace files (Docs, Sheets) may not support direct content replacement — use the native editor for those.
- The service account must have write access to the file.
