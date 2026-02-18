---
name: "workflow.cancel"
description: "Remove a scheduled workflow's cron job."
handler: "Assistant.Skills.Workflow.Cancel"
confirm: true
tags:
  - workflow
  - write
  - scheduled
---

# workflow.cancel

Cancel a scheduled workflow by removing its Quantum cron job. Optionally
deletes the workflow file from disk.

## Parameters

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| name | string | yes | Name of the workflow to cancel |
| delete | boolean | no | Also delete the workflow file (default false) |

## Response

Returns confirmation:

```
Workflow 'morning-digest' cron job removed. File preserved at priv/workflows/morning-digest.md.
```

With `--delete`:

```
Workflow 'morning-digest' canceled and file deleted.
```

## Example

```
/workflow.cancel --name morning-digest
/workflow.cancel --name morning-digest --delete
```

## Usage Notes

- This is a mutating skill — the assistant will confirm before executing.
- Without `--delete`, the file is preserved and can be re-scheduled later.
- With `--delete`, the workflow file is permanently removed.
