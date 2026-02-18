---
domain: workflow
description: "Workflow skills for creating, listing, running, and canceling scheduled prompt workflows."
---

# Workflow Domain

Skills for managing scheduled workflows. Workflows are prompt files stored in
`priv/workflows/` that can run on a cron schedule or be triggered manually.
Each workflow has a prompt body that is sent to the agent for execution, and
optionally posts the result to a Google Chat space.

## Skill Inventory

| Skill | Type | Purpose |
|-------|------|---------|
| workflow.create | Write | Create a new workflow prompt file |
| workflow.list | Read | List all workflows with schedule info |
| workflow.run | Write | Run a workflow immediately (bypass schedule) |
| workflow.cancel | Write | Remove a scheduled workflow's cron job |
