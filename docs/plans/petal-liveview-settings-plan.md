# Implementation Plan: Petal LiveView Settings + Analytics Frontend

> Created: 2026-02-19
> Status: PROPOSED
> Decision: Use Petal Components as the primary UI component library

## Summary

Build a minimal but extensible Phoenix LiveView admin frontend for Synaptic Assistant using Petal Components, with:

1. Model management (add/edit/select defaults)
2. Analytics page (cost, token usage, tool hits, failures, error rates)
3. App connection management (Google, HubSpot, future providers)
4. Workflow management UI
5. Skill permission scoping (for example, disable `email.send`)
6. Help/setup instructions for each integration

This app is currently webhook/API-only, so we need a browser/LiveView surface first, then settings features in phases.
Workflow editing will use a rendered in-place editor (no raw markdown shown), with markdown serialized and stored on the backend.
Workflow editor also includes per-workflow tool permissions so each workflow can run only approved tools.

---

## Why Petal

Petal was selected because it is the strongest fit for production stability and community size while still working cleanly with LiveView and HEEx.

Decision criteria used:

1. Library maturity and release history
2. Community adoption and support surface
3. Phoenix/LiveView compatibility and maintenance risk
4. Ability to ship quickly without replacing the app's architecture

---

## Product Scope

### In Scope (MVP)

1. Authenticated `/settings` area with a collapsible sidebar
2. Models page that uses our internal active model roster (name, input cost, output cost)
3. Role default mapping for assistant model usage (orchestrator/sub-agent/compaction/sentinel/etc.)
4. Analytics page with usage/cost/tool/failure reporting
5. App connections from a platform-controlled app catalog (initially Google placeholder + extensible provider cards)
6. Workflow list/create/edit for existing markdown workflow system with rendered editing, formatting toolbar, and autosave
7. Skill toggles with scoped enable/disable controls
8. Help content per integration using searchable guide cards and detail pages
9. Workflow scheduling UI that abstracts cron into recurrence controls (daily/weekly/monthly + time)
10. Workflow-specific tool permission selector (allowlist of tools each workflow can use)
11. Per-workflow enable/disable toggle directly on each workflow card

### Out of Scope (MVP)

1. Full redesign of orchestrator behavior
2. Replacing workflow markdown format with a new engine
3. Advanced multi-tenant RBAC
4. Dedicated provider-specific account management page in settings
5. Full third-party OAuth onboarding for every integration on day one
6. User-defined arbitrary custom webhook integrations

---

## Information Architecture

`/settings` with sections:

1. `General`
2. `Models`
3. `Analytics`
4. `Apps & Connections`
5. `Workflows`
6. `Skill Permissions`
7. `Help`

---

## ASCII Mockups

### 1. Settings Shell

```text
+----------------------------------------------------------------------------------+
| [Aperture] Synaptic Assistant                   [Collapse <<]  [User] [Sign out] |
+---------------------------+------------------------------------------------------+
| Settings                  | General                                              |
| > General                 | ---------------------------------------------------- |
|   Models                  | Welcome to Synaptic Assistant settings               |
|   Analytics               |                                                      |
|   Apps & Connections      | Quick Links                                          |
|   Workflows               | [Models] [Analytics] [Apps] [Workflows] [Skills]   |
|   Skill Permissions       |                                                      |
|   Help                    | Getting Started                                      |
|                           | - Sync models                                        |
|                           | - Connect approved apps                              |
|                           | - Configure workflows                                |
+---------------------------+------------------------------------------------------+
```

Collapsed state:

```text
+----------------------------------------------------------------------------------+
| [A] Synaptic Assistant                               [Expand >>] [User] [Sign out]|
+------+---------------------------------------------------------------------------+
|  G   | General                                                                   |
|  M   | Quick links + onboarding cards                                            |
|  A   |                                                                           |
|  C   |                                                                           |
|  W   |                                                                           |
|  S   |                                                                           |
|  H   |                                                                           |
+------+---------------------------------------------------------------------------+
```

### 2. Models Page

```text
+----------------------------------------------------------------------------------+
| Models                                                           [Sync Catalog]  |
| Source: OpenRouter user models    Last synced: 2026-02-19 08:00 UTC            |
|----------------------------------------------------------------------------------|
| Role Defaults                                                                     |
| Orchestrator [ anthropic/claude-sonnet-4-6           v ]                         |
| Sub-Agent    [ openai/gpt-5-mini                      v ]                         |
| Compaction   [ anthropic/claude-haiku-4-5-20251001   v ]                         |
| Sentinel     [ openai/gpt-5-mini                      v ]                         |
|----------------------------------------------------------------------------------|
| Model Catalog                                              [ + Add Local Model ] |
| [Search models...............................................................]    |
|----------------------------------------------------------------------------------|
| Model Name                              Input Cost            Output Cost          |
| Claude Sonnet 4.6                       $3.00 / 1M tokens    $15.00 / 1M tokens  |
| GPT-5 Mini                              $0.60 / 1M tokens    $2.40 / 1M tokens   |
| Gemini 3 Flash Preview                  $0.50 / 1M tokens    $3.00 / 1M tokens   |
+----------------------------------------------------------------------------------+
```

### 3. Analytics Page

```text
+----------------------------------------------------------------------------------+
| Analytics                                          Range [ Last 7 days v ] [Go] |
| Filters: Model [All v] Tool Domain [All v] Status [All v]                       |
|----------------------------------------------------------------------------------|
| +-------------------+ +-------------------+ +-------------------+ +------------+ |
| | Total Cost        | | Prompt Tokens     | | Completion Tokens | | Fail Rate  | |
| | $128.42           | | 4,221,110         | | 1,920,554         | | 2.8%       | |
| +-------------------+ +-------------------+ +-------------------+ +------------+ |
|----------------------------------------------------------------------------------|
| Cost / Day (chart)                                                               |
|  ^                                                                               |
|  |      /\      /\                                                               |
|  |  /\ /  \ /\ /  \__                                                            |
|  +---------------------------------------------------------------------> time    |
|----------------------------------------------------------------------------------|
| Top Tool Hits                                                                    |
| List Workflows 932 | Search Tasks 811 | Read Email 604 | Search Files 550      |
|----------------------------------------------------------------------------------|
| Recent Failures                                                                   |
| 2026-02-19 07:59 | Send Email    | timeout       | conversation: ...            |
| 2026-02-19 07:52 | List Calendar | api_error_429 | conversation: ...            |
+----------------------------------------------------------------------------------+
```

### 4. Apps & Connections Page

```text
+----------------------------------------------------------------------------------+
| Apps & Connections                                              [ + Add App ]   |
|----------------------------------------------------------------------------------|
| [Google Workspace]   Status: Connected   Last check: 2m ago     [Manage]        |
| Scopes: Gmail, Calendar, Drive                                              OK   |
|----------------------------------------------------------------------------------|
| [HubSpot]            Status: Not Connected                     [Connect]         |
| Scopes: CRM Contacts, Deals                                                      |
+----------------------------------------------------------------------------------+
```

Add App modal (catalog only):

```text
+---------------------------------------------------------------+
| Add App                                              [X]      |
|---------------------------------------------------------------|
| Search catalog: [ google .................................. ] |
|---------------------------------------------------------------|
| [Google Workspace]   Gmail, Calendar, Drive       [Add]       |
| [HubSpot]            Contacts, Deals              [Add]       |
| [Slack]              Channels, DMs                [Add]       |
|---------------------------------------------------------------|
| Note: Only approved apps are available in this catalog.       |
+---------------------------------------------------------------+
```

### 5. Workflows List Page (Card Based)

```text
+----------------------------------------------------------------------------------+
| Workflows                                                     [ + New Workflow ] |
|----------------------------------------------------------------------------------|
| [Search workflows............................................................]   |
|----------------------------------------------------------------------------------|
| +-----------------------------+  +-----------------------------+                 |
| | Daily Digest                |  | Weekly Summary              |                 |
| | Enabled: [ON]               |  | Enabled: [OFF]              |                 |
| | Daily at 8:00 AM            |  | Weekly on Monday at 9:00 AM |                 |
| | [icon:edit] [icon:copy]     |  | [icon:edit] [icon:copy]     |                 |
| +-----------------------------+  +-----------------------------+                 |
| +-----------------------------+                                                   |
| | Follow-up Reminder          |                                                   |
| | Enabled: [ON]               |                                                   |
| | Weekdays at 4:00 PM         |                                                   |
| | [icon:edit] [icon:copy]     |                                                   |
| +-----------------------------+                                                   |
+----------------------------------------------------------------------------------+
```

### 6. Workflow Editor Page (Single Content Pane)

```text
+----------------------------------------------------------------------------------+
| Workflows                           [Back to Workflows] [Reload Scheduler Now]     |
|----------------------------------------------------------------------------------|
| Editing: weekly-summary.md                                                      |
| Name        [ weekly-summary                                                 ]  |
| Description [ Weekly summary and follow-ups                                  ]  |
| Schedule    [ Weekly v ]  [ Monday v ]  [ 09:00 AM ]  (internally stored as cron) |
| Channel     [ google_chat                                                    ]  |
| Tools       [ Read Email x ] [ Search Tasks x ] [ List Calendar x ] [ + Add ]   |
|----------------------------------------------------------------------------------|
| Toolbar: [B] [I] [H1] [H2] [UL] [OL] [Link] [Code]                              |
|----------------------------------------------------------------------------------|
| Weekly Summary                                                                    |
|                                                                                  |
| Goals                                                                             |
| - Review open tasks                                                               |
| - Send stakeholder update                                                         |
|                                                                                  |
| (Rendered editing canvas: user edits formatted content directly)                  |
|                                                                                  |
| Status: Autosaved 2s ago                                                          |
+----------------------------------------------------------------------------------+
```

### 7. Skill Permissions Page

```text
+----------------------------------------------------------------------------------+
| Skill Permissions                                             Scope [ Global v ] |
|----------------------------------------------------------------------------------|
| [Search domain or skill.....................................................]    |
|----------------------------------------------------------------------------------|
| Domain                Skill                          Enabled                      |
| Email                 Send Email                     [OFF]                        |
| Email                 Read Email                     [ON ]                        |
| Workflow              Create Workflow                [ON ]                        |
| Files                 Archive Files                  [OFF]                        |
|----------------------------------------------------------------------------------|
| [ Save Permission Changes ]                                                      |
+----------------------------------------------------------------------------------+
```

### 8. Help Page (Card Catalog)

```text
+----------------------------------------------------------------------------------+
| Help & Setup                                                   [Search docs...]  |
|----------------------------------------------------------------------------------|
| [Google Workspace Setup] [HubSpot Setup] [Models Setup] [Workflows Guide]       |
| [Skill Permissions Guide] [Analytics Guide]                                       |
+----------------------------------------------------------------------------------+
```

### 9. Help Detail Page

```text
+----------------------------------------------------------------------------------+
| Help > Google Workspace Setup                               [Back to Help]      |
|----------------------------------------------------------------------------------|
| Google Workspace Setup                                                             |
|                                                                                   |
| 1. Click Apps & Connections                                                        |
| 2. Click Add App                                                                   |
| 3. Select Google Workspace                                                         |
| 4. Complete connection flow                                                        |
|                                                                                   |
| Related Guides: [Models Setup] [Workflows Guide]                                  |
+----------------------------------------------------------------------------------+
```

---

## Branding Plan

Use brand tokens globally in settings UI:

1. Primary Aqua: `#00A99D`
2. Secondary Purple: `#93278F`
3. Slate: `#33475B`
4. Accent Orange: `#F7931E`
5. Accent Blue: `#29ABE2`
6. Surface: `#FBF7F1`
7. Font family: `Montserrat` (light/normal/bold)

Logo usage:

1. Full text logo for header/sidebar
2. Aperture logo for compact nav/favicon treatment

---

## Technical Architecture

### 1. Web Foundation

Add browser/HTML/LiveView stack to the current API-only Phoenix setup:

1. Browser pipeline and session support in router
2. Static asset serving for CSS/fonts/logos
3. LiveView-enabled endpoint config
4. `Layouts.app` wrapper and `current_scope` wiring for all settings pages

### 2. UI Layer

1. Petal Components for base primitives (forms, tables, modals, nav)
2. Local wrapper components in `AssistantWeb.UI.*` to avoid vendor lock-in
3. LiveView pages for each settings section
4. Collapsible sidebar navigation (expanded + icon-only collapsed mode)
5. Rendered workflow editor component:
   - rich toolbar actions (bold, italic, headings, lists, links, code blocks)
   - in-place formatted editing (no raw markdown textbox in UI)
   - markdown serialization under the hood for persistence
   - autosave/hot-update to backend with short debounce
6. Workflow tool permission selector component:
   - searchable tool picker grouped by domain
   - selected tools displayed as removable chips/toggles with user-friendly names
   - stored as workflow-level allowlist metadata
7. Icon-first interaction model:
   - use icons for compact actions (edit, duplicate, delete, etc.)
   - include tooltips and accessible labels on all icon buttons
   - use Phoenix core `<.icon>` component (Heroicons) as default icon system for consistency

### 3. Auth Strategy

1. Use Phoenix-native auth (`phx.gen.auth` style architecture) for app login/session
2. Restrict settings routes to authenticated users/admin scope
3. Keep provider OAuth/auth flows separate from app login auth

### 4. Models Integration (Roster-Backed)

Use the assistant's internal model roster as the source for configuration and display.

1. Read active model roster from application config
2. Display/edit model metadata needed by operations (name, input cost, output cost)
3. Save role mappings used by orchestrator and sub-agent flows
4. Keep model management under `Models` in settings

### 5. Analytics Pipeline (Backend + UI)

Add an analytics subsystem that records and exposes:

1. LLM usage: prompt/completion/total tokens, cached tokens, reasoning/audio tokens
2. LLM costs: provider-reported cost when available and fallback cost classification
3. Tool activity: hit counts by skill/tool and success/failure rates
4. Reliability metrics: timeouts, API errors, and top failure reasons

Implementation direction:

1. Emit instrumentation events from orchestrator loop and sub-agent loop
2. Emit tool execution events from skill execution paths
3. Persist raw events in a file-backed event log for pre-launch builds
4. Build query layer for dashboard aggregations (hour/day/window filters), then migrate storage to DB when we go live

### 6. Extensible App Connections

Create provider-agnostic connection records for approved apps in a platform-managed catalog:

1. Provider identity (`google`, `hubspot`, future providers)
2. Connection status (`connected`, `expired`, `error`, `disconnected`)
3. Required scopes/permissions
4. Last successful sync/check timestamp
5. Add App flow uses a modal with searchable approved app list (no arbitrary custom app URL input in MVP)

### 7. Workflow Management

Build UI on top of the current markdown workflow system:

1. List workflows as cards (`priv/workflows/*.md`) on a dedicated list page
2. Open a separate workflow editor page from each card
3. Editor page includes a back button to return to workflow list
4. Workflow cards stay concise (name, enabled state, schedule, actions); channel is configured/viewed in editor detail
5. Create/edit metadata (`name`, `description`, `schedule`, `channel`)
6. Replace raw cron entry with a schedule builder UI:
   - recurrence dropdown (`Daily`, `Weekly`, `Monthly`, `Custom`)
   - time-of-day picker
   - day-of-week/day-of-month selectors when applicable
   - preview of the generated cron expression for transparency
7. Convert schedule builder selections into cron format for persisted workflow files
8. Edit prompt body in a rendered editor with toolbar actions (bold/italic/etc.)
9. Serialize rendered content to markdown and persist automatically via autosave/hot-update
10. Configure per-workflow tool permission allowlist in editor UI
11. Add per-workflow enable/disable toggle in list cards
12. Trigger scheduler reload after changes

Editor behavior requirements:

1. Source of truth is markdown text (no proprietary rich-text format)
2. Users edit rendered formatted content only; raw markdown is hidden from UI
3. Toolbar actions map to markdown-equivalent constructs in serialization
4. LLM/runtime continue reading normal markdown files with no conversion step at execution time
5. Source of truth for scheduler remains cron in workflow metadata, generated from user-friendly controls
6. Edits hot-update backend via debounced autosave and show save state (`Saving...`, `Saved`)
7. Source of truth for workflow tool permissions is metadata allowlist in workflow file
8. Runtime execution must enforce workflow allowlist before any tool execution
9. UI must show human-readable tool labels (`Read Email`) and never expose internal IDs (`email.read`) in normal workflow editor flows
10. Workflow `enabled` state is editable from list cards and enforced by scheduler/execution paths

### 8. Skill Permission Scoping

Use and extend `skill_configs` to support scope:

1. Global/workspace defaults
2. Optional per-user overrides
3. Optional per-channel overrides

Enforcement point:

1. Before skill execution in orchestration path, resolve effective skill permission for current context and block if disabled.
2. UI labels should be user-friendly (`Domain` + `Skill` display names) instead of dot-notation identifiers.

---

## Backend Instrumentation Plan

### Existing Signals (Already Present)

1. OpenRouter parsing already returns usage fields, including `cost`, from API responses
2. Orchestrator engine already accumulates usage in-memory per turn
3. No persistent analytics event pipeline exists yet

### Required Backend Updates

1. Ensure usage/cost from OpenRouter responses is propagated and persisted for:
   - orchestrator loop calls
   - sub-agent loop calls (currently missing usage accounting)
   - image generation calls where applicable
2. Emit structured events for each tool execution:
   - skill/tool name
   - success/failure status
   - duration
   - error classification
3. Add query APIs for analytics windows (for example: 24h, 7d, 30d)
4. Add optional rollup jobs for faster dashboard queries at higher volumes

### Proposed Event Capture Points

1. `Assistant.Orchestrator.LoopRunner` and `Assistant.Orchestrator.Engine` for LLM usage/cost
2. `Assistant.Orchestrator.SubAgent` for sub-agent LLM usage/cost + failure outcomes
3. `Assistant.Skills.Executor` for tool hit/failure/duration events
4. `Assistant.Orchestrator.Tools.DispatchAgent` and wait/result paths for agent-level outcomes

---

## Data Model Plan

### Existing Table Reuse

`skill_configs` exists and should be evolved instead of replaced.

### Proposed Additions

1. `integration_accounts`
   - provider
   - account identifier/display fields
   - status
   - metadata (non-secret)

2. `integration_secrets`
   - encrypted token/key material (Cloak)
   - expiry and rotation metadata

3. `model_preferences`
   - selected model IDs per role
   - optional scope columns (workspace/user)

4. `llm_usage_events`
   - timestamp
   - provider/model
   - context scope (`orchestrator`, `sub_agent`, `image`)
   - token fields (`prompt`, `completion`, `total`, cached/reasoning/audio)
   - cost fields (`provider_cost`, optional normalized cost)
   - request status/error metadata

5. `tool_execution_events`
   - timestamp
   - tool/skill id
   - conversation/user context
   - success/failure status
   - duration
   - error type/message fingerprint

6. `skill_configs` extension
   - add scope columns (for example `user_id`, `channel`)
   - add uniqueness constraints by scope

7. Workflow metadata extension (in markdown frontmatter, not a new table):
   - `allowed_tools`: list of tool/skill identifiers permitted for that workflow
   - optional `allowed_domains`: domain-level shortcut that expands to tool set
   - `enabled`: boolean for workflow-level activation/deactivation

---

## Delivery Phases

### Phase 0: Foundation (Web + Auth + UI Shell)

1. Enable browser pipeline and LiveView
2. Install/configure Petal
3. Implement branded settings shell and route protection

### Phase 1: Models

1. Pull and display model catalog from OpenRouter
2. Persist role default mappings
3. Add manual model add/edit UX for local overrides

### Phase 2: Analytics Backend Instrumentation

1. Persist LLM usage/cost events from orchestrator and sub-agents
2. Persist tool hit/failure/duration events
3. Add analytics query functions and aggregation endpoints

### Phase 3: Analytics UI

1. Build `/settings/analytics` page
2. Add cards/charts/tables for:
   - total cost
   - token usage
   - top tools by hits
   - failure rate and top errors
3. Add filters (time range, model, tool/domain, status)

### Phase 4: App Connections

1. Provider-agnostic connection cards
2. Google adapter first, extensible for additional providers
3. Health/status checks and reconnect UX

### Phase 5: Workflows UI

1. Card-based workflow list page
2. Separate workflow editor page with back navigation
3. Rendered in-place editor integration in LiveView editor form
4. Schedule builder UI (daily/weekly/monthly/custom + time/day selectors)
5. Cron generation + validation from schedule controls
6. Markdown editor toolbar (bold/italic/headings/lists/links/code)
7. Markdown serialization + debounced autosave hot-update behavior
8. Workflow tool permission selector UI + metadata persistence
9. Per-workflow card toggle UI (`enabled` on/off) + metadata persistence
10. Create/update workflow files as plain markdown
11. Scheduler reload and validation UX

### Phase 6: Skill Permissions

1. Scoped skill toggles
2. Permission resolution + runtime enforcement
3. Audit logging for permission changes

### Phase 7: Help + Onboarding

1. Card-based help guide catalog with search/filter
2. Separate help detail pages with back navigation
3. Per-provider setup instructions
4. Required permissions/scopes checklist
5. Troubleshooting section

---

## Security Plan

1. Encrypt provider tokens/secrets at rest (Cloak)
2. Never log raw tokens/keys
3. CSRF/session protections for browser routes
4. Permission checks on every settings mutation
5. Enforce app allowlist in Add App flow (no arbitrary custom integration endpoints)
6. Redact sensitive payload data from analytics events
7. Enforce workflow-level tool allowlists at runtime to reduce workflow blast radius

---

## Testing Plan

1. LiveView tests for each settings section
2. ConnCase tests for auth + route access control
3. Integration tests for OpenRouter model sync
4. Data-layer tests for analytics event ingestion and aggregate queries
5. Data-layer tests for scoped skill config resolution
6. Workflow file write/update tests and scheduler reload behavior
7. Accuracy tests that validate token/cost totals from API usage payloads
8. Workflow editor tests validating rendered edits + toolbar actions serialize to expected markdown output
9. UI tests for collapsible sidebar and workflow/help back navigation flows
10. Schedule builder tests for recurrence/time/day -> cron conversion correctness
11. Autosave tests for debounced hot-update and save-state indicators
12. Workflow tool allowlist tests (editor persistence + runtime enforcement)
13. Workflow enabled-toggle tests (card toggle persistence + scheduler/runtime enforcement)
14. Accessibility tests for icon-only actions (tooltip/aria labels present)

Definition of done for each phase:

1. Feature implemented
2. Tests passing
3. Documentation updated
4. `mix precommit` passes

---

## Risks and Mitigations

1. Risk: OpenRouter cost data may be missing/null for some responses
   - Mitigation: persist nullable provider cost and separate estimated cost logic
2. Risk: Introducing browser stack into API-only app could create regressions
   - Mitigation: isolate browser routes/pipeline, keep webhook routes unchanged
3. Risk: Permission model ambiguity (global vs per-user)
   - Mitigation: ship global default first, then scoped overrides in Phase 6
4. Risk: Config split between YAML and DB causes drift
   - Mitigation: establish source-of-truth rules per setting and explicit sync logic
5. Risk: Analytics query cost grows with event volume
   - Mitigation: add rollup tables/jobs and bounded retention windows

---

## Open Decisions Required

1. Source of truth for model defaults:
   - Keep in `config/config.yaml`
   - Move to DB
   - Hybrid (YAML defaults + DB overrides)
2. Skill permission precedence:
   - global -> channel -> user
   - global -> user -> channel
3. Analytics retention and granularity:
   - raw events only (short retention)
   - raw + daily rollups
   - rollups only after N days
4. Cost source of truth:
   - provider-reported `usage.cost` only
   - provider cost + local estimate fallback
5. Workflow ownership:
   - shared workspace workflows
   - user-owned workflows
   - both
6. Help guide ownership:
   - static internal docs only
   - admin-editable guides in DB
   - hybrid

---

## Immediate Next Step

Run a Phase 0 technical spike to establish:

1. Browser + LiveView + Petal baseline
2. Authenticated settings shell
3. Brand token system (colors/font/logo integration)
4. Analytics schema spike (`llm_usage_events`, `tool_execution_events`) and one ingestion path

No provider account management UI in the spike beyond placeholders.
