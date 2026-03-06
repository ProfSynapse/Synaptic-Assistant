---
name: "agents.query_subagent"
description: "Ask a focused question about a sibling sub-agent's latest snapshot without interrupting it."
handler: "Assistant.Skills.Agents.QuerySubagent"
tags:
  - agents
  - coordination
  - orchestration
  - read
parameters:
  - name: "agent_id"
    type: "string"
    required: true
    description: "The target sibling sub-agent to inspect."
  - name: "question"
    type: "string"
    required: true
    description: "A concrete question about the target agent's progress, blockers, or findings."
---

# agents.query_subagent

Ask a focused question about another sub-agent using that agent's latest published transcript snapshot.
This is read-only. It does not interrupt, pause, resume, or cancel the target agent.

## Parameters

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| agent_id | string | yes | The sibling sub-agent to inspect |
| question | string | yes | The concrete question to answer from the snapshot |

## Response

Returns a structured summary including:

- a short summary of the target agent's current work
- an answer to the specific question
- current progress
- blockers
- open questions

## Usage Notes

- Use this only for sibling agents in the same orchestration wave unless the orchestrator explicitly granted access.
- Do not query yourself.
- If the target agent has not published enough progress yet, the answer may be partial.
