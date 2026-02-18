---
domain: tasks
description: "Task management skills for creating, searching, viewing, updating, and archiving tasks."
---

# Tasks Domain

Skills for managing tasks within the assistant's task management system. Includes
creating new tasks with priorities and due dates, searching with full-text and
structured filters, viewing full task details, updating fields with incremental
tag support, and soft-deleting (archiving) tasks.

## Skill Inventory

| Skill | Type | Purpose |
|-------|------|---------|
| tasks.create | Write | Create a new task with title, priority, tags, due date |
| tasks.search | Read | Search tasks by text query, status, priority, tags, dates |
| tasks.get | Read | Fetch full task details including subtasks, comments, history |
| tasks.update | Write | Update task fields (status, priority, title, tags, etc.) |
| tasks.delete | Write | Soft-delete (archive) a task with optional reason |
