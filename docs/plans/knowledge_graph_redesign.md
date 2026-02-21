# Knowledge Graph & Memory UI Redesign

## Overview
This document outlines the plan to transform the existing "Memory" settings tab into an interactive, Obsidian-style Knowledge Graph dashboard. The goal is to provide a visual, explorable representation of the user's entities, memories, and transcripts, while retaining access to the raw tabular data via accordions.

## 1. UI Restructuring (`lib/assistant_web/components/settings_page.ex`)
- [ ] **Update Navigation Icon:** Change the "Memory" sidebar icon from `hero-document-text` to `hero-cpu` (or similar) to represent the "Assistant's Brain".
- [ ] **Create Global Filter Bar:** Add a top-level card with a search input and timeframe/type dropdowns that control the entire page's state.
- [ ] **Add Graph Container:** Create a large, prominent `div` with `phx-hook="KnowledgeGraph"` and `phx-update="ignore"` to host the canvas.
- [ ] **Wrap Existing Data in Accordions:** Move the existing "Transcripts" and "Memories" tables into native HTML `<details>` and `<summary>` tags below the graph.

## 2. LiveView State Management (`lib/assistant_web/live/settings_live.ex`)
- [ ] **Initialize Graph State:** Add `graph_filters`, `loaded_node_ids`, and `graph_data` to the `mount/3` assigns.
- [ ] **Handle Global Filters:** Create a `handle_event("update_global_filters", ...)` that updates the filters and re-queries the graph, memories, and transcripts simultaneously.
- [ ] **Handle Graph Initialization:** Create a `handle_event("init_graph", ...)` that pushes the initial seed data to the JS hook when the graph mounts.
- [ ] **Handle Node Expansion:** Create a `handle_event("expand_node", ...)` that fetches neighbors for a clicked node and pushes them to the JS hook.

## 3. Backend Data Fetching (`lib/assistant/memory_graph.ex`)
- [ ] **Create Context Module:** Create a new file `lib/assistant/memory_graph.ex`.
- [ ] **Implement `get_initial_graph/2`:** Query the most recent `MemoryEntity` and `MemoryEntry` records for the user and format them into `%{nodes: [...], links: [...]}`.
- [ ] **Implement `expand_node/3`:** Query `MemoryEntityRelation` and `MemoryEntityMention` to find neighbors of a specific node and format them.

## 4. Frontend JavaScript Integration (`priv/static/assets/app.js` & Layouts)
- [ ] **Include Graph Library:** Add the `force-graph` CDN script tag to the root layout (`lib/assistant_web/components/layouts.ex` or `root.html.heex`).
- [ ] **Create Phoenix Hook:** Add `Hooks.KnowledgeGraph` to `app.js`.
- [ ] **Initialize ForceGraph:** Instantiate the graph on the element, configuring node labels, colors, and link arrows.
- [ ] **Wire Up Events:** 
  - Listen for `render_graph` to set initial data.
  - Listen for `append_graph` to merge new nodes/links.
  - Trigger `expand_node` when a user clicks a node on the canvas.

## 5. Styling & Polish (`assets/css/app.css`)
- [ ] **Graph Container Styles:** Ensure the graph container has a fixed height (e.g., `min-h-[500px]`), relative positioning, and proper borders.
- [ ] **Accordion Styles:** Style the `<details>` and `<summary>` tags to look like native cards with chevron rotation animations.
- [ ] **Filter Bar Styles:** Ensure the global filter bar is sticky or prominently displayed at the top of the section.