# Spec: Central Chat Interface

> Created: 2026-03-03
> Updated: 2026-03-04
> Status: PROPOSED
> Direction: Chat-first single conversation, with inspect-only trace modals

## Summary

Synaptic Assistant should have one authenticated chat surface for the signed-in user.

This page is not a workspace dashboard, not a transcript browser, and not a search surface. It is the main place to talk to the assistant.

Core product shape:

1. One canonical conversation per user
2. One in-app composer for direct chat
3. External messages from Telegram, Slack, Discord, Google Chat, and future channels land in the same conversation
4. Tool calls, sub-agent runs, and task side effects appear as lightweight inline cards
5. Those cards open read-only detail modals when the user wants to inspect them

The center of gravity should be "chat", not "operations console".

## Product Decisions

### What this page is for

- Reading and continuing the single user conversation
- Seeing where a message came from
- Seeing that tools or sub-agents ran
- Optionally opening a modal to inspect what happened
- Sending a new message directly inside the app

### What this page is not for

- Cross-conversation navigation
- Search-heavy exploration
- Memory retrieval browsing
- Operational control of tools or sub-agents
- Manual orchestration of background work

### Explicit UX stance

- The default reading mode is chat bubbles / chat cards
- Trace is secondary
- Search should stay in the Memory area, not in this primary chat surface
- Tool and sub-agent detail should be inspectable, not interactive

## Mental Model

The user has one ongoing conversation with Synaptic Assistant.

- Messages from any source are merged into the same conversation
- The user can reply from inside the app at any time
- A source chip explains where a message came from
- Assistant responses remain plain-language first
- System activity stays tucked behind compact cards and modals

This should feel closer to a premium messenger than a dashboard.

## Route And Auth Placement

This page should be an authenticated LiveView.

### Router placement

- Pipeline: existing `[:browser, :require_authenticated_settings_user]`
- `live_session`: existing `:require_authenticated_settings_user`
- Why: this page is the main signed-in conversation surface, it needs auth redirects, and it needs `@current_scope` on the socket

Do not create a second `live_session :require_authenticated_settings_user`.

### Rollout route

- Phase 1 route: `/workspace`
- Likely long-term home route: `/`

Why:

- `/workspace` is the safest rollout path while behavior settles
- If the chat becomes the main product surface, it should eventually replace the signed-in landing page

## UX Shape

### Main feed rules

- The feed is one upward-scrollable conversation
- User and assistant messages are the primary visual units
- Channel-originated messages should look like normal messages, with a source chip
- Assistant responses may include a compact "activity" block underneath when tools or sub-agents ran
- Activity blocks should never dominate the page

### Composer rules

- The composer should feel like a modern chat input, not a form footer
- Use one rounded pill text input
- Place a circular send button at the right edge
- The send icon should be an upward arrow
- Visual target:
  - `( text input                              ^ )`
- The composer should stay pinned to the bottom of the viewport
- Keep it single-purpose in v1:
  - no search
  - no tool picker
  - no attachment tray unless added later on purpose

### Trace presentation rules

Trace should be visible enough to build trust, but quiet enough to preserve conversational flow.

Inline trace presentation:

- Small summary cards under an assistant response
- Examples:
  - `2 tools used`
  - `1 sub-agent ran`
  - `3 tasks updated`
  - `run failed`
- Each card can show state: running, completed, failed, awaiting
- Each card has one primary action: `Inspect`

Expanded trace presentation:

- Opens in a modal on desktop
- Opens in a full-width slide-over on narrow screens
- Read-only
- No "resume", "retry", "cancel", or tool-level controls in v1

### Tool card behavior

Tool cards should be small and skimmable.

Inline card content:

- tool name or count
- status
- short summary if available
- no synthetic metrics

V1 inspect modal should only show fields we actually have:

- tool name when present in persisted `tool_calls`
- tool call arguments when persisted
- matched tool result content when persisted
- `tool_call_id` when useful for correlation

Do not promise or invent:

- per-tool duration
- exact start / finish timestamps
- normalized structured result objects
- execution metadata that is not currently persisted

### Sub-agent card behavior

Sub-agent cards should feel like "the assistant spun off a worker to help".

Inline card content:

- sub-agent label or purpose
- live status
- compact progress text

V1 inspect modal should include:

- mission text, collapsed by default
  - label can be `Show mission`, `Show prompt`, or `More`
  - opening it reveals the full mission text that was sent to the sub-agent
- status from live `SubAgent.get_status/1` when the run is still available
- `result` text when present
- `tool_calls_used`
- `duration_ms`
- transcript section:
  - live transcript while the sub-agent is still running, if the runtime exposes it
  - historical transcript after completion, if a completed transcript has been persisted and can be loaded
  - if the sub-agent is paused / awaiting orchestrator input, that state should appear inline in the transcript rather than in a separate special section
  - `reason` / `partial_history` should render as part of that transcript flow when available
  - if neither is available, fall back to result text only

Do not promise or invent:

- a complete historical event log for every run
- step-by-step progress snapshots unless the live runtime actually exposes them

If a sub-agent is still running, the modal can live-update via polling or PubSub. The user can watch it, but not steer it.

### Task side effects

Task changes should usually stay summarized inside the assistant reply or run summary.

Examples:

- `Created 1 task`
- `Updated 3 tasks`
- `Commented on T-104`

If deeper detail is needed, include it inside the same inspect modal instead of creating a separate workflow surface.

## ASCII Layout

### Desktop

```text
+------------------------------------------------------------------------------------------------------+
| Synaptic Assistant                                                                                   |
+------------------------------------------------------------------------------------------------------+
|                                                                                                      |
|   [ older messages above ]                                                                           |
|                                                                                                      |
|   Alex  9:42 AM  [Telegram]                                                                          |
|   Can you send Bob the overdue tasks?                                                                |
|                                                                                                      |
|   Synaptic  9:42 AM                                                                                  |
|   I found 7 overdue tasks and sent Bob a summary.                                                    |
|                                                                                                      |
|   [ 2 tools completed ]   [ 1 task update ]   [ Inspect run ]                                       |
|                                                                                                      |
|   Alex  10:03 AM  [In App]                                                                           |
|   What happened with the design review?                                                              |
|                                                                                                      |
|   Synaptic  10:03 AM                                                                                 |
|   I asked a sub-agent to pull the latest notes. It is still running.                                 |
|                                                                                                      |
|   [ Sub-agent running ]   [ Inspect run ]                                                           |
|                                                                                                      |
|                                                                                                      |
|   -----------------------------------------------------------------------------------------------    |
|   ( Message Synaptic across all connected channels..........................................  ^ )    |
+------------------------------------------------------------------------------------------------------+
```

### Modal: tool run

```text
+----------------------------------------------------------------------------------+
| Tool Run                                                        [x]              |
|----------------------------------------------------------------------------------|
| Name       [tool name if available]                                              |
| Status     [status]                                                              |
|----------------------------------------------------------------------------------|
| Arguments (only if persisted)                                                    |
| [arguments payload]                                                              |
|----------------------------------------------------------------------------------|
| Result content (only if persisted)                                               |
| [result text]                                                                    |
+----------------------------------------------------------------------------------+
```

### Modal: sub-agent run

```text
+----------------------------------------------------------------------------------+
| Sub-agent                                                        [x]             |
|----------------------------------------------------------------------------------|
| Mission     [Show mission +]                                                     |
| Status      [status]                                                             |
| Tool Calls  [count if available]                                                 |
| Duration    [duration if available]                                              |
|----------------------------------------------------------------------------------|
| Mission text (expanded only when opened)                                         |
| [full mission / prompt text]                                                     |
+----------------------------------------------------------------------------------+
| Transcript                                                                       |
| [live transcript while running]                                                  |
| [paused/awaiting state appears inline here when relevant]                        |
| or                                                                               |
| [historical transcript if persisted]                                             |
| or                                                                               |
| [result text if transcript unavailable]                                          |
+----------------------------------------------------------------------------------+
```

### Mobile

```text
+---------------------------------------------+
| Synaptic Assistant                           |
+---------------------------------------------+
| Alex [Slack]                                 |
| Can you summarize today's blockers?          |
|                                             |
| Synaptic                                     |
| I am checking tasks and recent notes now.    |
| [1 tool running] [Inspect]                   |
|                                             |
| Synaptic                                     |
| I have a draft summary ready.                |
| [1 sub-agent completed] [Inspect]            |
|                                             |
|-------------------------------               |
| ( Message Synaptic........  ^ )              |
+---------------------------------------------+
```

On mobile, inspect actions should open a `SlideOver` or full-screen modal instead of a side inspector.
Do not assume a dedicated chat-level menu button in this view. If broader app navigation exists, it should come from the surrounding app shell, not from the chat spec itself.

## Visual Direction

Stay close to the existing app language.

- Keep the current warm, light visual tone
- Use the existing brand typography and spacing rhythm
- Let the conversation breathe with generous vertical spacing
- Make trace cards visually quieter than actual chat messages
- Use state color sparingly:
  - aqua/info for running
  - green for completed
  - orange for awaiting
  - red for failed

The page should look like a polished chat app with structured receipts, not an admin dashboard.

## Petal Component Map

| Need | Petal component |
| --- | --- |
| chat message containers | lightweight custom bubble wrapper (no dedicated Petal chat primitive) |
| source and status labels | `Badge` |
| trace summary cards | `Card` |
| inspect overlays | `Modal`, `SlideOver` |
| live run state | `Badge` (+ optional `Progress`) |
| rounded composer shell | custom wrapper + `input` styling |
| circular send control | `Button.icon_button` |
| loading states | `Skeleton` |

## LiveView Implementation Strategy

### Recommendation

Use one root LiveView with a streamed chat feed and modal-based detail views.

### Why this fits

- LiveView is already the app's browser stack
- The page is mostly append-heavy conversation state
- The surface benefits from server-driven truth and lightweight updates
- The UI does not need SPA-style client state

### Specific patterns

1. Use `stream/4` for the main chat feed
   - New messages append at the bottom
   - Older messages prepend above on demand
   - The feed stays efficient as history grows

2. Keep modal state in LiveView assigns plus URL state where useful
   - `selected_run_id`
   - `selected_run_type`
   - `push_patch` only if deep-linking to inspect state is desirable

3. Use `assign_async/3` or `start_async/3` for modal detail loading
   - Loading large tool payloads or transcript detail should not block the feed

4. Use polling first for live sub-agent modals
   - Poll only while a run modal is open and status is non-terminal
   - Move to PubSub later if a normalized event stream exists

5. Keep custom JavaScript minimal
   - scroll anchoring for chat
   - auto-resize composer if needed

### Suggested LiveView shape

- `AssistantWeb.WorkspaceLive`
  - header
  - streamed chat feed
  - composer state
  - selected inspect modal state

Supporting components:

- `MessageBubbleComponent`
- `RunSummaryCardComponent`
- `ToolRunModalComponent`
- `SubAgentModalComponent`

## Data / Read Model Requirements

The chat page should read as one conversation, even if system traces come from multiple underlying records.

### Canonical chat data needed

- One canonical orchestrator conversation for the user
- Ordered message history for that conversation
- Source metadata for each inbound message
- Assistant replies stored durably

### Persisted source metadata contract (v1)

User messages should carry a persisted `messages.metadata` map with:

```elixir
%{
  "source" => %{
    "kind" => "in_app" | "channel" | "channel_replay",
    "channel" => "in_app" | "google_chat" | "slack" | "telegram" | "discord" | "...",
    # optional identifiers
    "message_id" => "...",
    "space_id" => "...",
    "thread_id" => "...",
    "external_user_id" => "...",
    "user_display_name" => "...",
    "user_email" => "..."
  },
  # optional raw adapter context
  "channel_metadata" => %{...}
}
```

UI rule:

- Source chips in the chat feed must be rendered from persisted metadata only.
- If metadata is missing, render no chip rather than guessing.

### Trace data needed for inspect cards

- tool call summary per turn
- tool result summary per turn
- sub-agent run metadata and current status
- sub-agent mission text
- sub-agent transcript source:
  - live runtime transcript while active, if exposed
  - completed transcript lookup after finish, if persisted
- task side effects attached to the parent turn

### Read model recommendation

Build the page from a chat-first turn model, not raw event rows.

Suggested feed unit:

```elixir
%{
  id: "...",
  source_message: %{...},
  assistant_message: %{...},
  source: %{channel: "telegram", label: "Telegram"},
  run_summary: %{
    status: :completed,
    tool_count: 2,
    sub_agent_count: 1,
    task_change_count: 3,
    failure_count: 0
  },
  inspect_targets: [
    %{type: :tool_run, id: "..."},
    %{type: :sub_agent_run, id: "..."}
  ]
}
```

The main feed should not render raw `tool_call` and `tool_result` rows as if they were user-facing chat bubbles.

### Truthfulness rule

The UI spec should not assume trace fields that the backend does not currently expose.

- If a field is not durably stored or available from a live runtime API, do not design around it as if it always exists
- Inspect modals should render partial truth cleanly instead of manufacturing a "complete" run view
- It is acceptable for a modal to show only a small amount of data in v1 if that is the truthful state of the system
- Mission text is different: for sub-agents, it should be treated as required inspect data because the orchestrator dispatch includes a mission

## Search And Memory

Search should stay in the Memory area.

Reason:

- This page should optimize for conversation flow
- The Memory area is already the better home for retrieval, filtering, and archive-style browsing
- Mixing search controls into the main chat page will push the UI back toward a dashboard

Possible later link:

- Memory search result can deep-link into the canonical chat at a specific turn

## Phase Plan

### Phase 1: chat-first MVP

- `/workspace` authenticated LiveView
- single canonical conversation
- merged in-app and external-channel messages
- direct composer
- inline run summary cards
- inspect-only modals for tools and sub-agents

### Phase 2: live inspect experience

- live sub-agent progress while modal is open
- richer summaries for task side effects
- better source badges and delivery metadata

### Phase 3: home-page promotion

- decide whether `/workspace` becomes `/`
- keep Memory focused on search, retrieval, and transcript browsing

## Non-Goals

- Do not build a multi-session sidebar
- Do not put search-first controls into the main chat page
- Do not make tools or sub-agents directly controllable from the modal in v1
- Do not render raw JSON or raw trace logs inline in the primary conversation flow
- Do not treat sub-agents as peer chats

## Open Decisions

1. Should channel source be shown on every external message bubble, or only when the source changes?
2. Should inspect modals be deep-linkable with `push_patch`, or stay purely local UI state in v1?
3. Should active sub-agent cards auto-expand a tiny progress snippet inline, or always stay collapsed until `Inspect`?
