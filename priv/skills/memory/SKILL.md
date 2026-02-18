---
domain: memory
description: "Memory management skills for persistent knowledge storage, semantic search, and entity graph maintenance."
---

# Memory Domain

Skills for managing the assistant's long-term memory system. Includes
semantic search over memory entries, saving new memories, extracting
and maintaining an entity-relation knowledge graph with temporal validity,
and compacting conversation history into structured memory.

## Skill Inventory

| Skill | Type | Purpose |
|-------|------|---------|
| memory.search_memories | Read | Semantic search across stored memory entries |
| memory.save_memory | Write | Persist a new memory entry with topics |
| memory.extract_entities | Write | Extract entities and relations from text |
| memory.close_relation | Write | Close a relation and optionally open a replacement |
| memory.query_entity_graph | Read | Fetch active relations for an entity |
| memory.compact_conversation | Write | Summarize message range into memory entries |

## Search-First Rule

Write skills (save_memory, extract_entities, close_relation, compact_conversation)
require a preceding read skill call (search_memories or query_entity_graph) in the
same turn. This prevents duplicate entries and conflicting knowledge.
