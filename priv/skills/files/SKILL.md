---
domain: files
description: "File management skills for searching, reading, creating, updating, and archiving files in Google Drive."
---

# Files Domain

Skills for interacting with Google Drive files. Includes searching files by name
and type, reading file content (with automatic export for Google Workspace
documents), creating new files, updating existing file content via text
replacement, and archiving files to a designated folder.

## Skill Inventory

| Skill | Type | Purpose |
|-------|------|---------|
| files.search | Read | Search Drive files by query, type, and folder |
| files.read | Read | Read file content by ID (auto-exports Google Workspace files) |
| files.write | Write | Create a new file in Google Drive |
| files.update | Write | Update file content by replacing text (sed-like) |
| files.archive | Write | Move a file to the Archive folder |
