---
name: "memory.save_memory"
description: "Write a new memory entry with content, topics, and provenance metadata."
tags:
  - memory
  - write
  - storage
---

# memory.save_memory

Persist a new memory entry for the current user. Requires a preceding search
to verify no duplicate or conflicting entry exists (search-first enforcement).

## Parameters

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| content | string | yes | The memory content to store (factual, concise) |
| topics | array[string] | yes | Topic labels for categorization and retrieval |
| source_type | string | no | Origin: "conversation", "compaction", "manual" (default: "conversation") |
| confidence | float | no | Confidence level 0.0-1.0 (default: 0.8) |
| source_conversation_id | string | no | UUID of the originating conversation |
| source_message_range | object | no | `{start_idx: int, end_idx: int}` for compaction provenance |

## Response

Returns a JSON object:

```json
{
  "id": "uuid",
  "content": "Stored memory text",
  "topics": ["topic1"],
  "created_at": "2026-02-18T12:00:00Z"
}
```

## Usage Notes

- Always search first to avoid duplicates.
- Keep content factual and specific — avoid vague or speculative statements.
- Include all relevant entity names in the content for future graph extraction.
- Topics should be 2-5 words each, lowercase, describing the subject matter.
