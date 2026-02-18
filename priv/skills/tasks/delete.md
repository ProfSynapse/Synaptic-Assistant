---
name: "tasks.delete"
description: "Soft-delete (archive) a task with an optional reason."
handler: "Assistant.Skills.Tasks.Delete"
tags:
  - tasks
  - write
  - delete
  - archive
---

# tasks.delete

Soft-delete a task by setting its archived_at timestamp and archive_reason.
The task record is preserved for audit purposes and can still be retrieved
by ID via tasks.get. Archived tasks are excluded from search results by default.

## Parameters

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| _positional | string | yes | Task ID (UUID) or short ID to archive |
| reason | string | no | Archive reason (default: "cancelled") |

## Response

Returns a confirmation:

```
Task T-001 archived (reason: cancelled).
```

## Usage Notes

- This is a soft delete — the record remains in the database.
- Archived tasks do not appear in search results unless explicitly requested.
- The archive reason is stored for audit and can be any descriptive string.
- Common reasons: "cancelled", "duplicate", "completed_elsewhere", "no_longer_needed".
