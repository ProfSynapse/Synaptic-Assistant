---
name: "memory.search_memories"
description: "Semantic search across memory entries for the current user."
handler: "Assistant.Skills.Memory.Search"
tags:
  - memory
  - search
  - retrieval
---

# memory.search_memories

Search the user's stored memory entries using semantic similarity and optional filters.
Returns ranked results with relevance scores.

## Parameters

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| query | string | yes | Natural language search query |
| limit | integer | no | Maximum results to return (default: 10, max: 50) |
| topics | array[string] | no | Filter by topic labels |
| min_confidence | float | no | Minimum confidence threshold (0.0-1.0, default: 0.3) |
| time_range | object | no | Filter by creation time: `{after: ISO8601, before: ISO8601}` |

## Response

Returns a JSON object:

```json
{
  "results": [
    {
      "id": "uuid",
      "content": "Memory entry text",
      "topics": ["topic1", "topic2"],
      "confidence": 0.87,
      "created_at": "2026-02-18T12:00:00Z",
      "source_type": "conversation | compaction | manual"
    }
  ],
  "total_count": 42,
  "query_tokens_used": 15
}
```

## Usage Notes

- Always call this before saving new memories to check for duplicates.
- Use `topics` filter to narrow searches within known domains.
- Results are ordered by relevance score descending.
- The `min_confidence` threshold filters out weak matches.
