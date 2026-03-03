# Spec: Central Workspace Chat Interface

> Created: 2026-03-03
> Status: PROPOSED
> Recommendation: Use a single timeline-first conversation with unified cross-channel history, not a multi-session chat sidebar

## Summary

Synaptic Assistant should have one authenticated timeline-first conversation, not a ChatGPT-style list of separate chats. The main screen should behave like a central command surface:

1. One persistent in-app composer for the signed-in user
2. One merged upward-scrollable timeline for prompts, assistant replies, tool calls, sub-agents, and task changes
3. One canonical user conversation that collects activity from Telegram, Slack, Discord, Google Chat, and in-app chat
4. One detail inspector for drilling into raw trace data without overwhelming the main feed

The right UI shape for this stack is a Phoenix LiveView workspace that renders a single timeline conversation, streams older and newer history into the feed, uses Petal components for structure and interaction, and treats the existing `conversations`, `messages`, `tasks`, and sub-agent traces as underlying system data rather than end-user "chat sessions".

## Why This Shape

### Product constraints

- The product wants a central repository and single conversation, not a list of named chats
- The UI must expose more than plain messages: tool calls, agent branches, task side effects, and failures
- The UI should fit the existing Phoenix LiveView + Petal stack instead of introducing a second frontend architecture
- The page should become the main authenticated home surface over time
- The feed should feel like a timeline you can scroll upward through, closer to a unified message history than a workflow console

### Decision matrix

| Option | Fit for "single central spot" | Good at trace visibility | Fit for LiveView/Petal | Recommendation |
| --- | --- | --- | --- | --- |
| Multi-session chat sidebar | Poor | Poor | Good | Reject |
| Single timeline conversation + inspector | Strong | Strong | Strong | Recommend |
| Task-first board with chat as secondary | Medium | Medium | Good | Secondary view only |

### Why the multi-session pattern is wrong here

- It teaches the user to think in separate chats, but the product requirement is one canonical conversation per user
- It buries operational trace detail behind per-chat navigation
- It does not give tasks and agent state first-class representation

## Repo Findings

### What already exists

- Phoenix 1.8 + LiveView are already in use
- `petal_components` is already installed and globally imported
- There is already an authenticated settings shell and a transcript browser in the Memory section
- The data model already includes:
  - `conversations`
  - `messages`
  - `tasks`
  - `task_history`
  - `execution_logs`
  - parent/child conversations for sub-agent hierarchy
- The architecture docs already describe orchestrator/sub-agent behavior and task management

### Important current gaps

The central UI should not be designed as if the trace data is fully persisted today, because it is not.

| Area | Current state | UI implication |
| --- | --- | --- |
| `conversations` / `messages` persistence | Schemas and query helpers exist, but the orchestrator appears to keep most turn history in GenServer state today | A read-only transcript UI will be incomplete unless runtime persistence is wired in |
| `execution_logs` | Dispatch creates a row, but status/result lifecycle updates are not yet the primary trace source | Agent cards cannot rely on DB execution logs alone |
| live agent progress | `SubAgent.get_status/1` exposes runtime status, but there is no workspace-specific event bus yet | Active state likely starts with polling, then moves to PubSub |
| analytics | Dashboard analytics are JSONL file-backed | Good for summary widgets, not good as the primary workspace event source |

This means the UI spec must include a backend trace-truth phase before the interface can be considered authoritative.

## Route And Auth Placement

This page should be an authenticated LiveView.

### Router placement

- Pipeline: existing `[:browser, :require_authenticated_settings_user]`
- `live_session`: existing `:require_authenticated_settings_user`
- Why: the workspace is the primary signed-in operator surface, it requires auth redirects, and it needs `@current_scope` on the socket

Do not create a second `live_session :require_authenticated_settings_user`.

### Rollout recommendation

- Phase 1 route: `/workspace`
- Long-term home route: `/`
- Keep `SettingsLive` on `/settings`

Reasoning:

- Shipping first on `/workspace` avoids unnecessary route churn while the behavior stabilizes
- Once the workspace is proven, it should become the authenticated home page because it is the real center of the product

## UX Recommendation

### Mental model

The user sees one conversation timeline, not many chats.

- The main feed is the conversation
- Older history is above, newer history is below, and the user scrolls upward for the past
- The composer always writes into the same canonical conversation
- Messages from Telegram, Slack, Discord, Google Chat, and in-app chat all land in that same conversation
- The right inspector shows exact details for the selected event
- The left rail is for filters and search, not chat history

### Desired feel

The visual reference should be closer to a search-driven timeline than a folder of separate chats.

- Think "single stream of important moments" rather than "many rooms"
- Search and filters should feel first-class
- The feed should remain chat-readable
- Tool traces and agent branches should appear as expandable inline events, not as a second dashboard

### Primary feed unit: timeline groups

The main feed still needs to feel like chat. It should not default to a dense operational table or a workflow board.

The best balance is a timeline where top-level user and assistant messages read like normal chat, but system-side activity is grouped inline beneath the related assistant response.

Instead of a flat raw-message list, the feed should use timeline groups:

- Trigger: user prompt, scheduled workflow trigger, or inbound external message
- Assistant summary: the top-level result in plain language
- Nested trace: tool calls, sub-agent branches, task changes, failures
- Status badges: running, awaiting input, completed, failed

Raw event-by-event trace should still exist, but as an expanded detail view, not the default reading mode.

## ASCII Layout

### Desktop timeline conversation

```text
+-------------------------------------------------------------------------------------------------------------------+
| Synaptic Assistant                                      [Search timeline......................] [All Sources v]     |
|                                                         [All Status v] [Tasks v] [Failures v]                      |
+-----------------------------+----------------------------------------------------------------+----------------------+
| Filters / Search            | Unified Conversation                                           | Inspector            |
|-----------------------------|----------------------------------------------------------------|----------------------|
| Quick Views                 | [ older history above ]                                        | Selected Event       |
| [Everything]                |                                                                | ------------------- |
| [Messages]                  | 9:42 AM  Telegram  Alex                                        | Source: Telegram     |
| [Tool Activity]             | "Can you send me the overdue tasks?"                           | Type: tool call      |
| [Tasks]                     |                                                                | Status: completed    |
| [Awaiting Input]            | 9:42 AM  Assistant                                             | Duration: 420ms      |
| [Failures]                  | I found 7 overdue tasks and sent the summary.                  |                      |
|                             | [2 tool calls] [1 task update] [show details]                  | Parameters           |
| Search                      |                                                                | { ... }              |
| Query [.................]   |   tasks.search   completed                                     |                      |
|                             |   email.send     completed                                     | Result               |
| Source [all v]              |   T-104 Deploy v2 -> in_progress                               | { ... }              |
| Event  [all v]              |                                                                |                      |
| Status [all v]              | 10:03 AM  In-App                                               | Related Items        |
|                             | "What happened with Bob?"                                      | - T-104              |
|                             |                                                                | - Agent task_search  |
|                             | 10:03 AM  Assistant                                            |                      |
|                             | Bob got the summary in Slack and email.                        | [Open Raw JSON]      |
|                             | [1 sub-agent] [show details]                                   | [Open Transcript]    |
|                             |                                                                |                      |
|                             | [ composer pinned to bottom ]                                  |                      |
|                             | [ Ask Synaptic across all channels.......................... ]  |                      |
|                             | [ Send ]                                                       |                      |
+-----------------------------+----------------------------------------------------------------+----------------------+
```

### Expanded timeline group structure

```text
+--------------------------------------------------------------------------------------------------+
| 10:14 AM  Telegram  Alex                                                          [Open Inspector] |
| USER MESSAGE                                                                                     |
| Find overdue tasks and send Bob a summary.                                                       |
|--------------------------------------------------------------------------------------------------|
| 10:14 AM  Assistant                                                                               |
| I found 7 overdue tasks, emailed Bob, and marked 3 items in progress.                           |
|--------------------------------------------------------------------------------------------------|
| BADGES: [completed] [2 tools] [1 sub-agent] [3 task changes] [source: telegram]                |
|--------------------------------------------------------------------------------------------------|
| Agents                                                                                           |
|   task_search                  [completed]   [progress 100%]                                     |
|     recent activity: planning -> tasks.search -> summarize                                       |
|--------------------------------------------------------------------------------------------------|
| Tools                                                                                            |
|   tasks.search                 [ok]        180ms                                                 |
|   email.send                   [ok]        240ms                                                 |
|--------------------------------------------------------------------------------------------------|
| Tasks                                                                                            |
|   T-104  Deploy v2              in_progress                                                      |
|   T-211  Q1 client follow-up    comment added                                                    |
+--------------------------------------------------------------------------------------------------+
```

## Visual Direction

Stay inside the existing Synaptic Assistant visual language instead of inventing a brand new dashboard style.

- Keep the current warm/light branded surface and Montserrat-based identity
- Use Petal cards, badges, tabs, and slide-overs as the structural primitives
- Make the center column feel more like a premium timeline than an admin panel
- Use color to separate state, not decoration:
  - aqua/info for active
  - green for completed
  - orange for awaiting/operator input
  - red for failed
- Use subtle separators, source chips, and grouped inline event blocks to distinguish sub-agent work from top-level assistant output

## Petal Component Map

The stack already has the right UI primitives. No second component library is needed.

| Need | Petal component |
| --- | --- |
| top-level quick views | `Tabs` |
| timeline event containers | `Card` |
| status and source labeling | `Badge` |
| nested trace detail | `Accordion` |
| detail inspector on narrow screens | `SlideOver` |
| task / tool detail tables | `Table` |
| running-state indicators | `Progress` |
| loading placeholders | `Skeleton` |
| actions | `Button`, `Dropdown`, `Modal` |

## LiveView Implementation Strategy

### Recommendation

Use one root LiveView with a streamed timeline, upward history loading, and async detail loading.

### Why this is the best fit

- LiveView is already the app's browser stack
- The workspace is mostly server-state plus incremental updates
- Chat/timeline items are append-heavy and history loading is incremental, which fits LiveView streams well
- The page needs quick, resilient interactions rather than a large client-side state machine

### Specific patterns to use

1. Use `stream/4` for the center conversation timeline
   - New items append at the bottom
   - Older history can prepend above on demand
   - Large collections should not fully re-render on every event
   - Good fit for active runs and timeline history loading

2. Use `assign_async/3` or `start_async/3` for the inspector and expensive side data
   - Loading a selected event should not block the composer or feed
   - Related task details, raw transcript JSON, and large trace payloads are good async candidates

3. Use URL state for selection, search, and filter persistence
   - `push_patch` for selected event, quick view, search, and filters
   - Deep links to a task, failure, or specific trace event become possible

4. Keep custom JavaScript minimal
   - One hook for feed scroll anchoring / "stick to newest"
   - One hook if needed for keyboard shortcuts or inspector sizing
   - Avoid introducing a SPA state layer

### Recommended root LiveView shape

```text
AssistantWeb.WorkspaceLive
  - header / search / filters
  - streamed conversation timeline
  - pinned composer
  - inspector state
  - quick view selection
  - active-run polling or PubSub subscription
  - incremental history loading
```

### Recommended component breakdown

```text
AssistantWeb.Components.Workspace.Shell
AssistantWeb.Components.Workspace.FilterRail
AssistantWeb.Components.Workspace.Timeline
AssistantWeb.Components.Workspace.MessageGroup
AssistantWeb.Components.Workspace.TraceBlock
AssistantWeb.Components.Workspace.AgentBranch
AssistantWeb.Components.Workspace.TaskEffects
AssistantWeb.Components.Workspace.Composer
AssistantWeb.Components.Workspace.Inspector
```

Use function components unless a section needs isolated lifecycle or event targeting.

## Data Model Recommendation

### Human-facing model

- One canonical conversation per user
- One merged timeline that includes in-app messages and external channel messages
- No user-visible conversation list

### Machine-facing model

Keep the existing underlying distinctions:

- root orchestrator conversations
- child sub-agent conversations
- messages
- execution logs
- task mutations

The UI should merge those into one canonical user conversation read model instead of exposing them directly as separate chats.

### Canonical conversation model

The product behavior should be:

- one canonical conversation per linked user
- every inbound message from any supported channel attaches to that same canonical conversation
- in-app prompts attach to that same canonical conversation

The implementation does not need to discard source metadata. It should preserve:

- source channel
- source message id
- source thread / room / space id
- delivery metadata needed for replies

That gives the product the single-conversation experience without losing channel semantics.

### Persistent in-app conversation

For browser-authored prompts, use the same canonical conversation per linked `users` row.

- The workspace should use the linked chat/user identity, not the raw `settings_user.id`
- Reuse the existing `settings_user -> user` bridge pattern already present in the settings context
- This preserves compatibility with memory, tasks, and future cross-channel linking

### Recommended read model

Create a dedicated workspace query layer instead of driving the page from `Assistant.Transcripts` directly.

Suggested responsibility:

```text
Assistant.Workspace
  - list_feed(current_scope, filters)
  - get_feed_item(current_scope, id)
  - list_active_runs(current_scope)
  - send_prompt(current_scope, prompt)
  - get_workspace_conversation(current_scope)
```

### Suggested normalized feed item shape

```elixir
%{
  id: "turn_...",
  canonical_conversation_id: "...",
  root_conversation_id: "...",
  source_kind: :in_app | :channel | :workflow | :system,
  source_channel: "telegram",
  status: :running | :awaiting | :completed | :failed,
  inserted_at: ~U[2026-03-03 15:14:00Z],
  trigger_text: "...",
  assistant_summary: "...",
  counts: %{tools: 2, agents: 1, task_changes: 3, failures: 0},
  related: %{task_ids: [...], execution_log_ids: [...], child_conversation_ids: [...]}
}
```

The feed item should be a UI read model, not a direct schema dump.

## Representation Rules

### Messages

- User and assistant text should be first-class visible blocks
- Source chips should indicate whether the message came from Telegram, Slack, Discord, Google Chat, or in-app chat
- Tool-only assistant turns should still render with a human summary line plus nested raw detail

### Tool calls

- Show collapsed by default inside the turn card
- Surface tool name, status, duration, and a short result summary
- Full params/result payload belong in the inspector

### Sub-agents

- Show them as branches inside the parent turn, not as separate top-level chats
- Each branch should show:
  - agent id
  - mission summary
  - status
  - tool count
  - recent activity tail

### Tasks

- Task side effects should be promoted out of the raw trace
- If a turn creates or changes tasks, show a dedicated "Task Effects" block
- A task-focused quick view should filter the timeline to turns with task mutations

### Search behavior

Search is first-class, not an afterthought.

- Search should operate across the single canonical conversation timeline
- Results should keep chronological context, not dump the user into separate session results
- Search hits should show source channel, timestamp, and a short surrounding preview

### Failures and awaiting input

- Failures and `awaiting_orchestrator` states should be elevated into quick views
- These should be immediately visible from the left rail and badge counts

## Backend Work Required Before The UI Is Truthful

This is the key implementation dependency.

### Phase 0 requirements

1. Persist root conversation lifecycle for real runtime turns
2. Persist message rows for user / assistant / tool_call / tool_result trace
3. Persist or reliably materialize sub-agent state transitions
4. Update execution log status/result through completion, failure, and timeout
5. Keep task mutations linked to source conversation and execution context

Without this, the UI can look polished but still lie about system state.

### Recommended event sources by concern

| Concern | Best source |
| --- | --- |
| historical user/assistant turns | `messages` |
| root run grouping | `conversations` |
| child agent grouping | child `conversations` + parent conversation id |
| tool lifecycle | persisted message rows and/or execution log updates |
| task side effects | `tasks` + `task_history` |
| active in-flight state | runtime poll initially, PubSub later |

## Polling vs PubSub

### Recommendation

- Start with short-interval polling for active runs
- Add PubSub once the event vocabulary stabilizes

### Why

- The runtime already exposes some state only in process memory
- Polling is simpler for the first truthful version of the workspace
- PubSub becomes worth it once there is a normalized workspace event stream

### Migration path

1. Poll `Assistant.Workspace.list_active_runs/1` every 1 to 2 seconds while active work exists
2. Once workspace events are normalized, broadcast `workspace:<user_id>` updates
3. Keep polling as a reconnect fallback

## Phased Delivery

### Phase 0: Trace truth

Goal: make the backend produce durable enough data for the UI.

- persist runtime conversations and messages
- complete execution log lifecycle updates
- define normalized workspace read model

### Phase 1: Read-only timeline viewer

Goal: ship the actual UI shell without composer write-path risk.

- `/workspace` authenticated LiveView
- filter rail
- single timeline conversation
- inspector
- active/failure/awaiting quick views
- upward history loading

### Phase 2: Web composer

Goal: let the user operate from the browser as the primary interface.

- in-app composer on the same canonical conversation
- composer + send flow
- assistant replies appended into the same unified timeline
- source channel marker for in-app messages

### Phase 3: Live operator controls

Goal: let the UI steer active work.

- inspect awaiting-agent context
- send agent update / resume
- interrupt or retry where supported

### Phase 4: Deeper task and trace workflows

Goal: make the workspace the real system console.

- stronger task-focused filtered views
- saved filters
- deep links to failures and related artifacts
- richer raw trace inspection

## What To Avoid

- Do not add a left sidebar of chat sessions
- Do not treat sub-agents as peer chats
- Do not make the primary feed raw JSON or raw tool output
- Do not build this as a separate SPA when LiveView already fits the behavior
- Do not overload the current Memory tab with the whole workspace concept
- Do not make the main screen feel like a workflow admin console before it feels like conversation history

## Research Basis

### External references

- Phoenix LiveView docs on streams: https://hexdocs.pm/phoenix_live_view/Phoenix.LiveView.html#stream/4
- Phoenix LiveView docs on async assigns and async work: https://hexdocs.pm/phoenix_live_view/Phoenix.LiveView.html#assign_async/3
- Petal Components docs: https://hexdocs.pm/petal_components/readme.html

### Repo sources reviewed

- `lib/assistant_web/router.ex`
- `lib/assistant_web/live/settings_live.ex`
- `lib/assistant_web/components/settings_page.ex`
- `lib/assistant_web/components/settings_page/memory.ex`
- `lib/assistant/transcripts.ex`
- `lib/assistant/schemas/conversation.ex`
- `lib/assistant/schemas/message.ex`
- `lib/assistant/schemas/task.ex`
- `lib/assistant/schemas/execution_log.ex`
- `lib/assistant/orchestrator/engine.ex`
- `lib/assistant/orchestrator/sub_agent.ex`
- `docs/architecture/sub-agent-orchestration.md`
- `docs/architecture/task-management-design.md`

## Open Questions

1. Should canonical conversation unification happen in the persistence model immediately, or should Phase 1 implement it first as a read-model merge over existing source conversations?
2. Do we want agent resume / interrupt controls in Phase 3, or is inspect-only sufficient for the first operational release?
3. Should the long-term home route switch to `/` as soon as the workspace ships, or only after one release cycle at `/workspace`?
