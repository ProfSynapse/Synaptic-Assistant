---
name: "email.search"
description: "Search Gmail messages by query, sender, recipient, and date range."
handler: "Assistant.Skills.Email.Search"
tags:
  - email
  - read
  - search
  - gmail
---

# email.search

Search Gmail for messages matching a text query, sender/recipient filters,
date range, and read status. Results include subject, sender, date, and a
short snippet.

## Parameters

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| query | string | no | Free-text search (matched against subject, body, etc.) |
| from | string | no | Filter by sender email address |
| to | string | no | Filter by recipient email address |
| after | string | no | Messages after this date (YYYY/MM/DD) |
| before | string | no | Messages before this date (YYYY/MM/DD) |
| limit | integer | no | Max results to return (default 10, max 50) |
| unread | boolean | no | Only show unread messages |
| full | boolean | no | Show full message content (headers + body) instead of summary |

## Response

Returns a formatted list:

```
Found 3 message(s):
- [msg123] Weekly standup notes
  From: alice@example.com | Date: Mon, 17 Feb 2026 09:00:00
  Summary of this week's standup discussion points...
- [msg456] Invoice #1042
  From: billing@vendor.com | Date: Fri, 14 Feb 2026 15:30:00
  Please find attached invoice for February services...
```

Returns "No messages found matching the given criteria." when no results match.

## Example

```
/email.search --from alice@example.com --after 2026/02/01 --unread
```

## Usage Notes

- All parameters are optional; calling with no parameters returns the 10 most recent messages.
- Date format for `--after` and `--before` is `YYYY/MM/DD`.
- The `--query` parameter uses Gmail search syntax (supports operators like `subject:`, `has:attachment`).
- The `--unread` flag is a boolean; include it to filter for unread messages only.
- Use `--full` to include complete message headers and body for each result instead of snippets.
