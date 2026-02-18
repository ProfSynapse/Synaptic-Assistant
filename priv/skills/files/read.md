---
name: "files.read"
description: "Read the content of a Google Drive file by its ID."
handler: "Assistant.Skills.Files.Read"
tags:
  - files
  - read
  - drive
---

# files.read

Read the content of a Google Drive file. For Google Workspace files (Docs,
Sheets, Slides), the content is automatically exported as plain text. For
regular files (PDF, text, etc.), the raw content is downloaded.

Content is truncated at 8,000 characters to protect LLM context budgets.

## Parameters

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| id | string | yes | The Google Drive file ID |
| format | string | no | Export MIME type for Workspace files (default: "text/plain") |

## Response

Returns the file content with a header:

```
## Q1 Report (exported as text)

This is the quarterly report for Q1 2026...
```

If the content exceeds 8,000 characters:

```
## Q1 Report (exported as text)

This is the quarterly report...

...content truncated at 8000 characters. Full file available in Drive.
```

## Usage Notes

- The `id` parameter is the Google Drive file ID (found via files.search or from a Drive URL).
- Google Workspace files (Docs, Sheets, Slides) are exported to plain text by default.
- Use `--format "text/csv"` to export a Google Sheet as CSV instead of plain text.
- Regular binary files (images, videos) will return raw bytes which may not display well as text.
- The 8,000 character limit prevents large files from consuming too much LLM context.
