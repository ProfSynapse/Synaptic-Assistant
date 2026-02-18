---
name: "memory.query_entity_graph"
description: "Fetch all active entity relations for a given entity in the knowledge graph."
tags:
  - memory
  - entities
  - knowledge-graph
  - retrieval
---

# memory.query_entity_graph

Query the entity-relation knowledge graph to retrieve all active (non-closed)
relations for a specific entity. Returns the entity's details and its connections.

## Parameters

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| entity_name | string | yes | Name of the entity to query |
| relation_types | array[string] | no | Filter by relation type(s) |
| include_closed | boolean | no | Include closed (historical) relations (default: false) |
| depth | integer | no | Graph traversal depth: 1 = direct, 2 = two hops (default: 1, max: 3) |

## Response

Returns a JSON object:

```json
{
  "entity": {
    "id": "uuid",
    "name": "Entity Name",
    "entity_type": "person",
    "attributes": {"email": "user@example.com"},
    "created_at": "2026-01-10T00:00:00Z"
  },
  "relations": [
    {
      "id": "uuid",
      "direction": "outgoing",
      "related_entity": {
        "id": "uuid",
        "name": "Project X",
        "entity_type": "project"
      },
      "relation_type": "works_on",
      "attributes": {"role": "developer"},
      "valid_from": "2026-01-15T00:00:00Z",
      "valid_to": null
    }
  ],
  "total_relations": 5
}
```

## Usage Notes

- This is a read skill — calling it satisfies the search-first requirement.
- Use `depth: 2` sparingly as it fans out quickly in dense graphs.
- Use `include_closed: true` to see historical changes to relations.
- Combine with `relation_types` filter for targeted queries.
