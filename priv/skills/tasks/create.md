---
name: "tasks.create"
description: "Create a new task with title, description, priority, tags, and due date."
handler: "Assistant.Skills.Tasks.Create"
tags:
  - tasks
  - write
  - create
---

# tasks.create

Create a new task in the task management system. Generates a sequential short ID
(e.g., T-001) for easy reference. Supports setting priority, tags, due date,
and nesting under a parent task for subtask relationships.

## Parameters

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| title | string | yes | Task title (concise, descriptive) |
| description | string | no | Detailed task description |
| priority | string | no | Priority level: "low", "medium", "high", "urgent" (default: "medium") |
| tags | string | no | Comma-separated tag labels (e.g., "bug, backend") |
| due | string | no | Due date in ISO 8601 format (e.g., "2026-03-01") |
| parent | string | no | Parent task ID (UUID) to create as subtask |

## Response

Returns a formatted summary:

```
Task created successfully.

ID: <uuid>
Short ID: T-001
Title: Fix login timeout
Status: todo
Priority: high
Due: 2026-03-01
Tags: bug, backend
```

## Usage Notes

- Title is the only required field.
- Tags are stored as an array; comma-separated input is split automatically.
- Due dates must be valid ISO 8601 date strings; invalid dates are silently ignored.
- Parent task must exist; otherwise the create will fail with a foreign key error.
