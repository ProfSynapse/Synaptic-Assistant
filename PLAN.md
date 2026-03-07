# Plan: Consolidation Mission — Knowledge Graph Updates

## Summary

Add a `:consolidate` mission type to the existing Memory Agent. When a memory is saved that mentions entities, the agent searches for related memories and entity graph connections, then updates the knowledge graph with any new relationships it discovers across memories.

No new schemas, no new workers, no new queues. This uses the existing agent loop, skill executor, and entity extraction infrastructure.

---

## File-by-file changes

### 1. `lib/assistant/memory/turn_classifier.ex`

**What:** Add a new classification action `"consolidate"` so the classifier can trigger graph consolidation after a `save_facts` dispatch.

**Changes:**
- Update `@classification_prompt` — add `consolidate` to the action descriptions:
  `consolidate: exchange references entities that may connect to previously stored memories`
- Update `@classification_response_format` — add `"consolidate"` to the `enum` array
- Add a new clause in `handle_classification/5`:
  ```elixir
  {:ok, "consolidate", reason} ->
    dispatch_to_memory_agent(user_id, :consolidate, %{
      conversation_id: conversation_id,
      user_id: user_id,
      user_message: user_message,
      assistant_response: assistant_response,
      trigger: :turn_classifier,
      classification_reason: reason
    })
  ```
- Also: after every `"save_facts"` dispatch, follow up with a `:consolidate` dispatch using the same params. This way, every time facts are saved, the agent also looks for cross-memory connections. The consolidate mission runs as a separate agent loop after the save completes.

**Why here:** The TurnClassifier is the existing trigger point for memory agent missions. Adding the consolidation trigger here keeps the dispatch logic in one place.

---

### 2. `lib/assistant/memory/agent.ex`

**What:** Add the `:consolidate` mission builder.

**Changes:**
- Add a new `build_mission_text(:consolidate, params)` clause after the existing mission builders (~line 933):

  ```elixir
  defp build_mission_text(:consolidate, params) do
    user_msg = params[:user_message] || ""
    assistant_msg = params[:assistant_response] || ""

    """
    Consolidate the knowledge graph based on the following exchange.

    User message: #{String.slice(user_msg, 0, 2000)}

    Assistant response: #{String.slice(assistant_msg, 0, 2000)}

    Steps:
    1. Search existing memories for entities and topics mentioned in this exchange.
    2. Query the entity graph for each entity found to see existing relations.
    3. Look for cross-memory connections: do any previously stored memories relate
       to each other in ways that weren't captured as entity relations?
       For example: Memory A says "Alice is an engineer", Memory B says
       "Project X needs engineers" → relation: Alice — candidate_for — Project X.
    4. For each new connection discovered, extract the entities and relations
       using the standard entity extraction format.
    5. For entities whose attributes have changed based on new information,
       close the old relations and open updated ones.
    6. Do NOT re-save memories. Only update the entity graph with new or
       changed relations between existing entities.
    """
  end
  ```

**Why here:** All mission types are defined as `build_mission_text/2` clauses in agent.ex. This follows the exact same pattern.

---

### 3. `priv/config/prompts/memory_agent.yaml`

**What:** Add a consolidation-specific instruction to the system prompt so the LLM knows how to handle consolidation missions differently from save missions.

**Changes:**
- Add a new paragraph under `## Core Responsibilities` (after item 5):

  ```yaml
  6. **Knowledge graph consolidation** — When given a consolidation mission,
     your goal is to find connections BETWEEN existing memories, not to save
     new ones. Search for related memories, query the entity graph, and look
     for relations that emerge from connecting the dots across multiple
     memories. Only extract entities and relations — do not create new
     memory entries during consolidation.
  ```

**Why here:** The system prompt guides the LLM's behavior during the agent loop. Without this instruction, the LLM might try to save new memories during a consolidation mission instead of focusing on graph updates.

---

### 4. `lib/assistant/memory/turn_classifier.ex` (trigger wiring)

**What:** Wire up the "save_facts then consolidate" chain.

**Changes:**
- In the existing `{:ok, "save_facts", reason}` clause, after dispatching `:save_and_extract`, add a second dispatch for `:consolidate` with the same params.
- This means every time facts are saved, a follow-up consolidation pass runs to check if the new facts connect to anything already in the graph.
- The Memory Agent already drops missions when busy (lines 309-319 in agent.ex), so if the save is still running, the consolidate mission gets dropped gracefully — it'll get another chance on the next turn.

**Alternative considered:** We could make `:save_and_extract` automatically chain into consolidation inside the agent. But that couples the two missions and makes the agent loop longer. Separate missions are cleaner — each has a focused goal.

---

## What we're NOT changing

- **No new schemas** — Consolidation insights are expressed as entity relations, not a separate table. The graph IS the consolidation output.
- **No new Oban workers** — The Memory Agent GenServer already handles async missions.
- **No new queues** — Uses the existing memory agent dispatch.
- **No new skills** — The agent already has `search_memories`, `query_entity_graph`, `extract_entities`, and `close_relation`. That's everything it needs.
- **No changes to `store.ex`** — Triggering happens via TurnClassifier PubSub, not store hooks.
- **No changes to `skill_executor.ex`** — The search-first rule already applies. The consolidation mission will naturally search before writing.

---

## How it works end-to-end

```
User says something → Engine publishes :turn_completed
  → TurnClassifier classifies the turn
  → If "save_facts":
      1. Dispatches :save_and_extract mission → agent saves facts + extracts entities
      2. Dispatches :consolidate mission → agent searches for cross-memory
         connections and updates entity graph
  → If "consolidate" (standalone):
      1. Dispatches :consolidate mission directly
```

The consolidation mission's LLM loop:
```
search_memories("Alice") → finds 3 related memories
query_entity_graph("Alice") → sees existing relations
query_entity_graph("Project X") → sees existing relations
# LLM reasons: Alice is an engineer, Project X needs engineers
extract_entities(entities: [...], relations: [{Alice, candidate_for, Project X}])
# Done — graph updated
```

---

## Test plan

- Unit test for `build_mission_text(:consolidate, params)` — verify it returns expected mission string
- Unit test for TurnClassifier handling `"consolidate"` classification
- Integration test: save two related memories, dispatch `:consolidate`, verify new relation appears in entity graph
