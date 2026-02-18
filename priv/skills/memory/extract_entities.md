---
name: "memory.extract_entities"
description: "Extract named entities and relations from text, upserting into the knowledge graph with temporal logic."
tags:
  - memory
  - entities
  - knowledge-graph
  - write
---

# memory.extract_entities

Analyze text to identify named entities (people, projects, tools, concepts, organizations)
and their relations. Upserts into the entity graph with temporal validity tracking.

## Parameters

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| text | string | yes | The text to analyze for entity extraction |
| source_conversation_id | string | no | UUID of the originating conversation for provenance |
| context_hint | string | no | Optional hint about the domain/context of the text |

## Response

Returns a JSON object:

```json
{
  "entities_found": [
    {
      "name": "Entity Name",
      "entity_type": "person | project | tool | concept | organization",
      "is_new": true
    }
  ],
  "relations_found": [
    {
      "from_entity": "Entity A",
      "to_entity": "Entity B",
      "relation_type": "works_on | uses | knows | part_of | related_to",
      "attributes": {"role": "lead developer"},
      "is_new": true
    }
  ],
  "entities_upserted": 3,
  "relations_upserted": 2
}
```

## Temporal Logic

- New entities are created with `valid_from = now()`.
- Existing entities are updated (attributes merged) without changing validity.
- New relations are opened with `valid_from = now(), valid_to = NULL`.
- If a conflicting relation exists (same entities, same type, different attributes),
  the agent should call `close_relation` first, then create the new one.
- Never delete — always close old relations and open new ones.

## Usage Notes

- Requires a preceding search (search_memories or query_entity_graph).
- If you discover a conflicting relation, use `close_relation` before creating a new one.
- Entity types should be normalized to the supported set.
- The `context_hint` helps disambiguate entity types (e.g., "This is about a software project").
