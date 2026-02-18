---
name: "memory.close_relation"
description: "Close an existing entity relation (set valid_to=now) and optionally open a replacement."
tags:
  - memory
  - entities
  - knowledge-graph
  - write
---

# memory.close_relation

Close an active entity relation by setting its `valid_to` timestamp to now.
Optionally creates a replacement relation with updated attributes in the same
operation, maintaining the temporal audit trail.

## Parameters

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| relation_id | string | yes | UUID of the relation to close |
| reason | string | no | Brief explanation for closing (stored in provenance) |
| replacement | object | no | New relation to open: `{relation_type, attributes}` |

## Response

Returns a JSON object:

```json
{
  "closed_relation": {
    "id": "uuid",
    "from_entity": "Entity A",
    "to_entity": "Entity B",
    "relation_type": "works_on",
    "valid_from": "2026-01-15T00:00:00Z",
    "valid_to": "2026-02-18T12:00:00Z"
  },
  "replacement_relation": {
    "id": "new-uuid",
    "from_entity": "Entity A",
    "to_entity": "Entity B",
    "relation_type": "works_on",
    "attributes": {"role": "tech lead"},
    "valid_from": "2026-02-18T12:00:00Z",
    "valid_to": null
  }
}
```

## Usage Notes

- Requires a preceding search to identify the relation to close.
- Never delete relations — close them with a valid_to timestamp.
- Use `replacement` when the relation itself is still valid but attributes changed
  (e.g., role change, status update).
- The `reason` field is important for provenance — always provide one.
- If no replacement is needed (relation ended), omit the `replacement` parameter.
