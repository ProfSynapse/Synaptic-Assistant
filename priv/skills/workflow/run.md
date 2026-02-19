---
name: "workflow.run"
description: "Run a workflow immediately, bypassing its cron schedule."
handler: "Assistant.Skills.Workflow.Run"
tags:
  - workflow
  - write
  - scheduled
---

# workflow.run

Run a named workflow immediately by enqueuing it as an Oban job. This bypasses
the cron schedule and is useful for testing or one-off execution.

## Parameters

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| name | string | yes | Name of the workflow to run |

## Response

Returns confirmation with the enqueued job ID:

```
Workflow 'morning-digest' enqueued for immediate execution (job #42).
```

Returns an error if the workflow does not exist.

## Example

```
/workflow.run --name morning-digest
```

## Usage Notes

- The workflow runs asynchronously via Oban in the `:scheduled` queue.
- If the workflow has a `channel` field, the result will be posted there.
- Use `/workflow.list` to see available workflow names.
