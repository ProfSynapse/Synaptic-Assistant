---
name: "tasks.search"
description: "Search tasks by full-text query, status, priority, tags, and date range."
handler: "Assistant.Skills.Tasks.Search"
tags:
  - tasks
  - read
  - search
---

# tasks.search

Search the task management system using full-text search and structured filters.
Results are ranked by relevance when a text query is provided, or by creation
date otherwise. Archived tasks are excluded by default.

## Parameters

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| query | string | no | Full-text search query across title and description |
| status | string | no | Filter by status: "todo", "in_progress", "blocked", "done", "cancelled" |
| priority | string | no | Filter by priority: "low", "medium", "high", "urgent" |
| assignee | string | no | Filter by assignee user ID |
| tags | string | no | Comma-separated tags to filter by (all must match) |
| due-before | string | no | ISO 8601 date; return tasks due before this date |
| due-after | string | no | ISO 8601 date; return tasks due after this date |

## Response

Returns a formatted list:

```
Found 3 task(s):
- [T-001] Fix login timeout (in_progress/high) | Due: 2026-03-01 | Tags: bug, backend
- [T-003] Add rate limiting (todo/medium) | Tags: backend, security
- [T-007] Update docs (todo/low)
```

Returns "No tasks found matching the given criteria." when no results match.

## Usage Notes

- All filters are optional; calling with no parameters returns all active tasks.
- Full-text search uses PostgreSQL tsvector weighted ranking (title > description).
- Tag filtering uses array containment — all specified tags must be present.
- Date filters can be combined (due-after + due-before) for a date range.
