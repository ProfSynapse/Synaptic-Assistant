---
name: "memory.compact_conversation"
description: "Summarize a message range into memory entries and extract entities for long-term storage."
tags:
  - memory
  - compaction
  - write
---

# memory.compact_conversation

Process a range of conversation messages, generating concise memory entries
and extracting entities/relations for the knowledge graph. This is the primary
mechanism for converting ephemeral conversation context into persistent memory.

## Parameters

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| conversation_id | string | yes | UUID of the conversation to compact |
| start_index | integer | yes | First message index in the range (inclusive) |
| end_index | integer | yes | Last message index in the range (inclusive) |
| focus_topics | array[string] | no | Prioritize extraction of these topics |

## Response

Returns a JSON object:

```json
{
  "memories_created": [
    {
      "id": "uuid",
      "content": "Summary of discussion segment",
      "topics": ["topic1", "topic2"],
      "source_type": "compaction"
    }
  ],
  "entities_extracted": [
    {
      "name": "Entity Name",
      "entity_type": "person",
      "is_new": true
    }
  ],
  "relations_extracted": [
    {
      "from_entity": "A",
      "to_entity": "B",
      "relation_type": "works_on"
    }
  ],
  "messages_processed": 25,
  "memories_count": 3,
  "entities_count": 5,
  "relations_count": 2
}
```

## Usage Notes

- Requires a preceding search to check for existing compaction of the same range.
- The message range should cover a coherent conversation segment.
- Use `focus_topics` when the conversation covers multiple subjects and you want
  to prioritize certain themes.
- Compaction is idempotent per conversation+range — re-compacting the same range
  should not create duplicates (check source_conversation_id + source_message_range).
- Each memory entry should be self-contained and understandable without the original messages.
