---
name: "tasks.update"
description: "Update task fields such as status, priority, title, tags, and assignee."
handler: "Assistant.Skills.Tasks.Update"
tags:
  - tasks
  - write
  - update
---

# tasks.update

Update one or more fields on an existing task. Changes are recorded in the task's
audit history with the user and conversation context. Supports incremental tag
modifications via --add-tag and --remove-tag flags.

## Parameters

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| _positional | string | yes | Task ID (UUID) or short ID to update |
| status | string | no | New status: "todo", "in_progress", "blocked", "done", "cancelled" |
| priority | string | no | New priority: "low", "medium", "high", "urgent" |
| title | string | no | New task title |
| description | string | no | New task description |
| assign | string | no | Assignee user ID |
| due | string | no | New due date in ISO 8601 format |
| add-tag | string | no | Comma-separated tags to add (merged with existing) |
| remove-tag | string | no | Comma-separated tags to remove from existing |

## Response

Returns a confirmation with changed fields:

```
Task T-001 updated. Changed: status, priority
```

## Usage Notes

- At least one field flag must be provided; otherwise an error is returned.
- Tag modifications are incremental: --add-tag merges, --remove-tag subtracts.
- All changes are atomically recorded in TaskHistory for audit purposes.
- The user ID and conversation ID are captured for audit context.
- Invalid due dates are silently ignored (field not updated).
