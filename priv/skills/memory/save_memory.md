---
name: "memory.save_memory"
description: "Write a new memory entry with content, topics, and provenance metadata."
handler: "Assistant.Skills.Memory.Save"
tags:
  - memory
  - write
  - storage
parameters:
  - name: "content"
    type: "string"
    required: true
    description: "The memory content to store (factual, concise)"
  - name: "topics"
    type: "array"
    items: "string"
    required: true
    description: "Topic labels for categorization and retrieval"
  - name: "source_type"
    type: "string"
    required: false
    description: "Origin: \"conversation\", \"compaction\", \"manual\" (default: \"conversation\")"
  - name: "confidence"
    type: "float"
    required: false
    description: "Confidence level 0.0-1.0 (default: 0.8)"
  - name: "source_conversation_id"
    type: "string"
    required: false
    description: "UUID of the originating conversation"
  - name: "search_queries"
    type: "array"
    items: "string"
    required: false
    description: "3-5 hypothetical questions this memory answers. Used for retrieval matching."
  - name: "source_message_range"
    type: "object"
    required: false
    description: "{start_idx: int, end_idx: int} for compaction provenance"
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
| search_queries | array[string] | no | 3-5 hypothetical questions this memory answers |
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
- Always include `search_queries` with 3-5 natural-language questions this memory answers.
  Example: for "Alice Chen is a senior backend engineer at TechCo specializing in distributed systems",
  generate: ["Who has distributed systems experience?", "What does Alice Chen do?", "Who works at TechCo?"]
