---
name: "files.archive"
description: "Move a file to the Archive folder in Google Drive."
handler: "Assistant.Skills.Files.Archive"
tags:
  - files
  - archive
  - drive
---

# files.archive

Move a file to an Archive folder in Google Drive. If no archive folder ID is
specified, searches for a root-level folder named "Archive" and creates one
if it does not exist.

## Parameters

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| id | string | yes | The Drive file ID to archive |
| folder | string | no | Archive folder ID (default: auto-detect or create "Archive") |

## Response

Returns confirmation that the file was moved:

```
Archived 'quarterly-report.txt' to Archive folder.
```

## Usage Notes

- The `id` parameter is the Drive file ID (not the file name).
- When `--folder` is omitted, the skill looks for a root-level folder named "Archive".
- If no "Archive" folder exists, one is created automatically.
- The file is removed from its current parent folder(s) and placed in the archive folder.
