---
name: "files.write"
description: "Create a new file in Google Drive."
handler: "Assistant.Skills.Files.Write"
tags:
  - files
  - write
  - drive
---

# files.write

Create a new file in Google Drive with the specified name and content. The file
can optionally be placed in a specific folder and given a custom MIME type.

## Parameters

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| name | string | yes | File name (include extension, e.g., "notes.txt") |
| content | string | yes | The text content of the file |
| folder | string | no | Parent folder ID to create the file in |
| type | string | no | MIME type of the file (default: "text/plain") |

## Response

Returns confirmation with the file details:

```
File created successfully.
Name: meeting-notes.txt
ID: 1a2b3c4d5e6f
Link: https://drive.google.com/file/d/1a2b3c4d5e6f/view
```

## Usage Notes

- The `name` parameter should include the file extension (e.g., "report.txt", "data.csv").
- The `folder` parameter accepts a Drive folder ID (not a folder name).
- The service account must have write access to the target folder.
- The `drive.file` scope limits write access to files created by the application.
- This creates a new file every time; it does not update existing files.
