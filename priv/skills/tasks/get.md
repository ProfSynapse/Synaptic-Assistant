---
name: "tasks.get"
description: "Fetch full task details including subtasks, comments, and audit history."
handler: "Assistant.Skills.Tasks.Get"
tags:
  - tasks
  - read
  - detail
---

# tasks.get

Retrieve a single task with full details. Accepts either a UUID or short ID
(e.g., "T-001"). Returns the task with its subtasks, comments, and recent
audit history entries.

## Parameters

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| _positional | string | yes | Task ID (UUID) or short ID (e.g., "T-001") |

## Response

Returns a formatted detail view:

```
## Task T-001

**Title:** Fix login timeout
**Status:** in_progress
**Priority:** high
**Description:** Users report 30s timeout on login endpoint
**Due:** 2026-03-01
**Tags:** bug, backend
**Started:** 2026-02-18 10:00:00Z

### Subtasks (2)
- [T-002] Investigate root cause (done)
- [T-003] Implement fix (in_progress)

### Comments (1)
- [Alice] Found the issue in auth middleware

### History (3 entries)
- status: todo -> in_progress
- priority: medium -> high
- description: (empty) -> Users report 30s timeout on login endpoint
```

## Usage Notes

- Accepts both UUID and short ID formats.
- History shows the 10 most recent entries; older entries are truncated with a count.
- Archived tasks are still retrievable by ID.
