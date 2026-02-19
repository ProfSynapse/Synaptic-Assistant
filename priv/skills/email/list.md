---
name: "email.list"
description: "List recent emails from a Gmail label."
handler: "Assistant.Skills.Email.List"
tags:
  - email
  - read
  - list
  - gmail
---

# email.list

List recent emails from a Gmail label without writing a search query. Defaults
to the INBOX label. Supports filtering by label and unread status.

## Parameters

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| limit | integer | no | Max messages to return (default 10, max 50) |
| unread | boolean | no | Only show unread messages |
| label | string | no | Gmail label to list from (default "INBOX"). Examples: "INBOX", "SENT", "DRAFTS", "STARRED" |
| full | boolean | no | Show full message content (headers + body) instead of summary |

## Response

Returns a numbered list:

```
Showing 3 message(s):
1. [msg123] Weekly standup notes
   From: alice@example.com | Date: Mon, 17 Feb 2026 09:00:00
2. [msg456] Invoice #1042
   From: billing@vendor.com | Date: Fri, 14 Feb 2026 15:30:00
3. [msg789] Welcome to the team
   From: hr@company.com | Date: Thu, 13 Feb 2026 11:00:00
```

Returns "No messages found." when the label is empty.

## Example

```
/email.list --label INBOX --unread --limit 5
```

## Usage Notes

- This is a convenience skill for browsing emails. Use `email.search` for advanced queries.
- The `--label` parameter accepts any Gmail label name (case-sensitive).
- Common labels: "INBOX", "SENT", "DRAFTS", "STARRED", "IMPORTANT", "TRASH", "SPAM".
- Use the message ID from the results with `email.read` to view full content.
- Use `--full` to include complete message headers and body for each result.
