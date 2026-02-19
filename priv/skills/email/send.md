---
name: "email.send"
description: "Send an email via Gmail."
handler: "Assistant.Skills.Email.Send"
tags:
  - email
  - write
  - send
  - gmail
---

# email.send

Send an email through Gmail. Requires recipient, subject, and body. Optionally
supports CC recipients. Header fields are validated to prevent injection attacks.

**This is a mutating action.** The assistant should confirm the recipient, subject,
and body with the user before executing this skill.

## Parameters

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| to | string | yes | Recipient email address |
| subject | string | yes | Email subject line |
| body | string | yes | Email body text (may be multiline) |
| cc | string | no | CC recipient email address |

## Response

Returns confirmation with the sent message details:

```
Email sent successfully.
To: bob@example.com
Subject: Meeting follow-up
Message ID: 18e1a2b3c4d5e6f7
```

## Example

```
/email.send --to bob@example.com --subject "Meeting follow-up" --body "Hi Bob, here are the action items from our meeting..."
```

## Usage Notes

- The `--to`, `--subject`, and `--cc` fields must not contain newlines (rejected as header injection).
- The `--body` field may contain newlines and is sent as-is.
- The email is sent from the authenticated Gmail account.
- This skill sends the email immediately; there is no draft or undo mechanism.
