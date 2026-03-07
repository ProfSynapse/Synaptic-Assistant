---
domain: files
description: "File management skills for searching, reading, writing, updating, and archiving files in the synced workspace."
---

# Files Domain

Skills for interacting with the user's synced workspace files. All operations
run against the local encrypted database — no direct Google Drive API calls are
made. Write operations are synced back to Drive asynchronously via the upstream
sync worker.

## Skill Inventory

| Skill | Type | Purpose |
|-------|------|---------|
| files.search | Read | Search workspace files by query, type, and folder |
| files.read | Read | Read file content by path or Drive file ID |
| files.write | Write | Write content to a workspace file |
| files.update | Write | Update file content by replacing text (sed-like) |
| files.archive | Write | Archive a file (local delete + upstream trash) |
