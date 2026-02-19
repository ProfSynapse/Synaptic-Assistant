---
name: "workflow.list"
description: "List all workflows with schedule and channel info."
handler: "Assistant.Skills.Workflow.List"
tags:
  - workflow
  - read
  - list
  - scheduled
---

# workflow.list

List all workflow prompt files in `priv/workflows/`. Shows each workflow's
name, description, cron schedule (if set), and delivery channel (if set).

## Parameters

This skill takes no parameters.

## Response

Returns a numbered list:

```
Found 2 workflow(s):
1. **morning-digest** — Summarize emails from the last 12 hours | Cron: 0 8 * * * | Channel: spaces/ABC
2. **weekly-report** — Generate weekly activity report | Cron: 0 9 * * 1
```

Returns "No workflows found." when the directory is empty.

## Example

```
/workflow.list
```

## Usage Notes

- This is a read-only skill — it does not modify any files.
- Use the workflow name from the results with `workflow.run` to execute immediately.
- Workflows without a `cron` field are manual-only (run via `workflow.run`).
