---
name: "workflow.create"
description: "Create a new scheduled workflow prompt file."
handler: "Assistant.Skills.Workflow.Create"
confirm: true
tags:
  - workflow
  - write
  - scheduled
---

# workflow.create

Create a new workflow prompt file in `priv/workflows/`. A workflow is a prompt
that can run on a cron schedule and optionally post its result to a Google Chat
space.

## Parameters

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| name | string | yes | Workflow name (lowercase, hyphens/underscores allowed) |
| description | string | yes | One-line description of the workflow |
| prompt | string | yes | The prompt body sent to the agent |
| cron | string | no | Cron expression for scheduling (e.g., "0 8 * * *") |
| channel | string | no | Google Chat space name for result delivery (e.g., "spaces/ABC") |

## Response

Returns confirmation with the created workflow details:

```
Workflow 'morning-digest' created at priv/workflows/morning-digest.md.
Schedule: 0 8 * * *
Channel: spaces/ABC
```

## Example

```
/workflow.create --name morning-digest --description "Summarize emails from the last 12 hours" --cron "0 8 * * *" --channel "spaces/ABC" --prompt "Read my emails from the last 12 hours and write up a concise digest."
```

## Usage Notes

- This is a mutating skill — the assistant will confirm before executing.
- If `--cron` is provided, the workflow will be scheduled immediately.
- The cron expression uses standard 5-field format: minute hour day month weekday.
- Without `--cron`, the workflow can still be run manually via `workflow.run`.
