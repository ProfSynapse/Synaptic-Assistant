---
name: "email.read"
description: "Read one or more Gmail messages by ID."
handler: "Assistant.Skills.Email.Read"
tags:
  - email
  - read
  - gmail
---

# email.read

Retrieve one or more Gmail messages by ID. Returns the full message headers
(subject, from, to, date) and the plain-text body content. Supports
comma-separated IDs for batch reading.

## Parameters

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| id | string | yes | Gmail message ID(s) — single ID or comma-separated (e.g. "id1,id2,id3") |

## Response

Returns the formatted email(s). Multiple messages are separated by a divider:

```
Subject: Weekly standup notes
From: alice@example.com
To: team@example.com
Date: Mon, 17 Feb 2026 09:00:00

Hi team,

Here are this week's standup notes...

---

Subject: Invoice #1042
From: billing@vendor.com
To: team@example.com
Date: Fri, 14 Feb 2026 15:30:00

Please find attached invoice for February services...
```

If a message ID is not found, the error is shown inline and remaining messages continue.

## Example

```
/email.read --id msg123abc
/email.read --id msg123abc,msg456def,msg789ghi
```

## Usage Notes

- The message ID can be obtained from `email.list` or `email.search` results (shown in brackets).
- Supports comma-separated IDs for reading multiple messages at once.
- If any individual fetch fails, the error appears inline for that ID; other messages are still returned.
- Only plain-text content is returned; HTML-only emails are decoded to text where possible.
- Attachments are not included in the response.
