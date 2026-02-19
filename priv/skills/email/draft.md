---
name: "email.draft"
description: "Create a Gmail draft (saved, not sent)."
handler: "Assistant.Skills.Email.Draft"
tags:
  - email
  - read
  - draft
  - gmail
---

# email.draft

Create a draft email in Gmail. The draft is saved to the user's Drafts folder
but is NOT sent. Requires recipient, subject, and body. Optionally supports
CC recipients. Header fields are validated to prevent injection attacks.

## Parameters

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| to | string | yes | Recipient email address |
| subject | string | yes | Email subject line |
| body | string | yes | Email body text (may be multiline) |
| cc | string | no | CC recipient email address |

## Response

Returns confirmation with the draft details:

```
Draft created successfully.
To: bob@example.com
Subject: Meeting follow-up
Draft ID: r1234567890
```

## Example

```
/email.draft --to bob@example.com --subject "Meeting follow-up" --body "Hi Bob, here are the action items..."
```

## Usage Notes

- The draft is saved but NOT sent. Use `email.send` to send an email immediately.
- The `--to`, `--subject`, and `--cc` fields must not contain newlines.
- The `--body` field may contain newlines and is saved as-is.
- The draft appears in the authenticated user's Drafts folder in Gmail.
