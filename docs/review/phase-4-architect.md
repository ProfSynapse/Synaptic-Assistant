# Phase 4 Architectural Review: Gmail, Calendar, and Workflow Skills

> Reviewer: pact-architect
> Date: 2026-02-18
> PR: #9
> Scope: Gmail + Calendar API clients, email/calendar/workflow skills, Quantum/Oban scheduler

---

## Executive Summary

Phase 4 adds three new skill domains (email, calendar, workflow) and their supporting infrastructure (Gmail/Calendar API clients, Quantum cron scheduler wiring, Oban WorkflowWorker). The architecture closely follows the patterns established in Phases 1-3. Integration clients mirror Drive; skill handlers implement the Handler behaviour consistently; the supervision tree additions are correctly ordered. The Integrations.Registry centralizes dependency wiring cleanly.

**Overall verdict**: Architecturally sound. Two minor items and several future-oriented recommendations. No blocking issues.

---

## 1. Integration Layer (Gmail + Calendar Clients)

### Pattern Consistency with Drive

Both `Google.Gmail` and `Google.Calendar` follow the established `Google.Drive` pattern precisely:

| Pattern | Drive | Gmail | Calendar |
|---------|-------|-------|----------|
| Goth auth via `Auth.token()` | Yes | Yes | Yes |
| `get_connection/0` private helper | Yes | Yes | Yes |
| GoogleApi struct normalization to plain maps | Yes | Yes | Yes |
| `{:ok, data} / {:error, reason}` return convention | Yes | Yes | Yes |
| Logger.warning on failure | Yes | Yes | Yes |
| @spec annotations on public functions | Yes | Yes | Yes |

**Verdict**: Excellent consistency. A developer familiar with Drive will immediately understand Gmail and Calendar.

### Gmail Client Review

**Strengths**:
- Header injection protection (`validate_headers/3`) at the integration layer, not just at the skill layer -- defense in depth
- RFC 2822 assembly is minimal and focused (text/plain only), appropriate for an assistant
- `search_messages/2` convenience function correctly composes `list_messages` + `get_message` sequentially
- base64url encoding/decoding handles the Gmail-specific padding correctly
- Nested MIME part extraction (`find_text_part/1`) handles multipart messages recursively

**Finding A1 (Minor)**: `list_messages/3` has `user_id \\ "me"` as the first default argument followed by `query` and `opts \\ []`. Elixir allows multiple default arguments but the caller pattern `Gmail.list_messages("me", query, max_results: 5)` forces specifying user_id explicitly to pass opts. The `search_messages/2` function works around this, but `email.list` skill at `list.ex:45` has to pass `"me"` explicitly. Consider reordering to `list_messages(query, opts \\ [])` with `user_id` inside opts, matching the Calendar client's approach where `calendar_id` is the first param with default.

- File: `lib/assistant/integrations/google/gmail.ex:28`
- Severity: Minor
- Impact: Ergonomics only, no functional issue

### Calendar Client Review

**Strengths**:
- `update_event/3` fetch-then-merge pattern avoids overwriting unspecified fields
- `merge_event_updates/2` pipeline is clean and type-safe (separate datetime/attendee paths)
- `normalize_event/1` extracts both dateTime and date (all-day event support)
- `build_attendees/1` correctly handles nil and empty list

**No issues found.** The Calendar client is the cleanest of the three Google API wrappers.

---

## 2. Integrations.Registry Pattern

`Integrations.Registry.default_integrations/0` centralizes the mapping between integration keys and modules. It is consumed in three places:
- `LoopRunner` (line 244) -- main orchestrator loop
- `SubAgent` (line 1155) -- sub-agent skill execution
- `Memory.Agent` (line 883) -- memory agent skill execution

**Strengths**:
- Single source of truth eliminates duplicated module references
- `Skills.Context` type spec mirrors the Registry keys
- Skill handlers pull integration modules from context, enabling test double injection

**Finding A2 (Future)**: The Registry always provides all integrations regardless of whether credentials are configured. When Goth is absent (dev environments without Google creds), all integration calls will fail at the `Auth.token()` level with a clear error. This is acceptable for now, but as more integrations are added (HubSpot is already in the Context type), consider making the registry conditional -- only include integrations whose credentials are configured. This would allow skill handlers to distinguish "not configured" from "configured but failing."

- Severity: Future
- Impact: Dev experience only, no production concern

---

## 3. Skill Module Structure

### Domain Organization

| Domain | Skills | Handler Module Pattern | Consistent |
|--------|--------|----------------------|------------|
| email | list, search, read, send, draft | `Skills.Email.{List,Search,Read,Send,Draft}` | Yes |
| calendar | list, create, update | `Skills.Calendar.{List,Create,Update}` | Yes |
| workflow | list, create, cancel, run, build | `Skills.Workflow.{List,Create,Cancel,Run,Build}` | Yes |
| files (existing) | search, read, write, update, archive | `Skills.Files.{Search,...}` | Yes |

The naming convention is consistent across all four domains.

### execute/2 Consistency

All Phase 4 skill handlers implement `@behaviour Assistant.Skills.Handler` and follow the `execute(flags, context)` contract. Return types are consistently `{:ok, %Result{}}`.

**Integration injection pattern comparison**:

| Approach | Used By | Pattern |
|----------|---------|---------|
| Fallback to module constant | Calendar skills, Files.Search | `Map.get(context.integrations, :calendar, Calendar)` |
| Nil check with early return | Email skills | `case Map.get(context.integrations, :gmail) do nil -> error` |

**Finding A3 (Minor)**: Calendar skills use a fallback-to-default pattern (`Map.get(context.integrations, :calendar, Calendar)`) while email skills use an explicit nil check. Both work, but they have subtly different failure modes: calendar skills silently fall through to the real module if the integration is missing from context (making it harder to detect misconfigured test contexts), while email skills fail explicitly. The email pattern is safer for testability. Recommend standardizing on the email pattern (explicit nil check) for all skills.

- Files: `lib/assistant/skills/calendar/create.ex:28`, `lib/assistant/skills/email/send.ex:28`
- Severity: Minor
- Impact: Test reliability, developer consistency

### Side Effects Tracking

Mutating skills correctly declare side effects:
- `email.send` -> `[:email_sent]`
- `calendar.create` -> `[:calendar_event_created]`
- `calendar.update` -> `[:calendar_event_updated]`
- `workflow.create` -> `[:workflow_created]`
- `workflow.cancel` -> `[:workflow_canceled]`

Read-only skills (email.list, email.search, email.read, calendar.list) correctly omit side effects.

`email.draft` does not declare a side effect. This is a judgment call -- a draft is saved to Gmail (a write operation) but is not sent. The current omission is acceptable since drafts are user-reviewable before sending.

---

## 4. Workflow System Design

### QuantumLoader <-> WorkflowWorker Separation

The design cleanly separates concerns:

```
QuantumLoader (GenServer)              WorkflowWorker (Oban.Worker)
  - Scans priv/workflows/*.md            - Receives {workflow_path}
  - Parses YAML frontmatter              - Reads workflow file
  - Registers Quantum cron jobs          - Executes prompt (stubbed)
  - Each job enqueues an Oban worker     - Posts result to channel
  - Supports reload/0 for hot updates    - 5-min uniqueness window
```

**Strengths**:
- Quantum handles timing; Oban handles reliable execution -- each does what it's best at
- QuantumLoader as GenServer with `reload/0` allows dynamic cron updates without restart
- WorkflowWorker uniqueness (`period: 300`) prevents duplicate runs within 5 minutes
- `max_attempts: 3` with Oban's built-in retry provides resilience
- Cron expression validation before registration prevents bad schedules from crashing Quantum

**No coupling issues found.** The boundary between QuantumLoader and WorkflowWorker is defined by the Oban job args contract (`%{workflow_path: path}`), which is a stable interface.

### workflow.create -> QuantumLoader Reload

`workflow.create` calls `QuantumLoader.reload/0` after writing the file. The reload removes all existing workflow jobs and re-registers from disk. This is correct but worth noting:

**Finding A4 (Future)**: `QuantumLoader.reload/0` does a full remove-and-rescan. For a small number of workflows this is fine, but if the workflow count grows significantly, consider adding an `add_workflow/1` API that registers a single new job without disrupting existing ones. Not needed now with expected workflow counts in the tens.

- Severity: Future
- Impact: Performance at scale only

### WorkflowWorker Execute Stub

`WorkflowWorker.execute_prompt/2` is correctly stubbed with a TODO referencing the orchestrator API:

```elixir
# TODO: Replace with actual agent execution when Assistant.Orchestrator
# exposes a run_prompt/2 or similar API.
```

This is architecturally appropriate -- the workflow system's shell is built and the execution hook is clearly documented for future wiring.

### Supervision Tree Ordering

```
maybe_goth() ->
  Assistant.Scheduler ->        # Quantum cron (before Oban)
  {Oban, ...} ->                # Job processing
  QuantumLoader ->              # Registers cron jobs (after both)
```

The ordering is correct:
1. Goth provides auth tokens
2. Scheduler (Quantum) must be running before QuantumLoader adds jobs
3. Oban must be running before QuantumLoader enqueues workers
4. QuantumLoader starts last and registers all cron jobs

---

## 5. Goth Domain-Wide Delegation

The `goth_source_opts/1` function in `application.ex:105-113` correctly handles the two modes:

| Mode | Config | Goth Source |
|------|--------|-------------|
| No impersonation | `GOOGLE_IMPERSONATE_EMAIL` absent | `[scopes: scopes]` |
| Domain-wide delegation | `GOOGLE_IMPERSONATE_EMAIL` set | `[claims: %{"scope" => ..., "sub" => email}]` |

The implementation correctly notes that Goth ignores `:scopes` when `:claims` is present, so the scope string is embedded in the claims map. This is a documented Goth behavior.

**No issues found.** The approach is clean and backward-compatible -- existing Drive/Chat functionality continues to work without GOOGLE_IMPERSONATE_EMAIL set.

---

## 6. Duplicated Utility Code

### resolve_workflows_dir Pattern

The following modules each contain an identical `resolve_workflows_dir/0` private function:

1. `Scheduler.QuantumLoader` (line 161)
2. `Skills.Workflow.Run` (line 88)
3. `Skills.Workflow.Create` (line 190)
4. `Skills.Workflow.Cancel` (line 122)
5. `Skills.Workflow.List` (line 96)

**Finding A5 (Minor)**: Five copies of the same resolution logic. Consider extracting to a shared utility -- either a function on the `Assistant.Scheduler` module or a `Workflow.Config` helper. The QuantumLoader already contains this logic and could expose it as a public function.

- Severity: Minor
- Impact: Maintenance only, not a correctness issue

### parse_limit Pattern

`email.list`, `email.search`, `calendar.list`, and `files.search` each contain nearly identical `parse_limit/1` implementations with the same default/max constants pattern. This is a common skill utility candidate.

**Finding A6 (Future)**: Consider extracting a `Skills.FlagUtils.parse_limit/3` helper (with configurable default and max). Low priority since the duplication is stable and localized.

- Severity: Future

---

## 7. Architecture Scorecard

| Criterion | Rating | Notes |
|-----------|--------|-------|
| **Pattern consistency** | Excellent | Gmail/Calendar clients mirror Drive precisely |
| **Separation of concerns** | Excellent | Integration clients / skill handlers / scheduler are cleanly separated |
| **Interface contracts** | Good | execute/2 consistent; minor inconsistency in integration injection pattern (A3) |
| **Dependency direction** | Excellent | Skills depend on integrations, never reverse; scheduler bridges Quantum->Oban correctly |
| **Supervision tree** | Excellent | QuantumLoader correctly placed after Scheduler and Oban |
| **Testability** | Good | Module injection via context.integrations enables test doubles; email pattern (nil check) is safer than calendar pattern (fallback default) |
| **Scalability** | Good | Registry is simple but adequate for current scale; QuantumLoader reload is full-rescan (A4) |
| **Security** | Good | Header injection defense at both integration and skill layers; covered in more detail by security reviewer |

---

## Findings Summary

| ID | Finding | Severity | Location |
|----|---------|----------|----------|
| A1 | Gmail `list_messages` arg ordering differs from Calendar/Drive pattern | Minor | `gmail.ex:28` |
| A2 | Registry always provides all integrations regardless of credential availability | Future | `registry.ex:41` |
| A3 | Inconsistent integration injection pattern: fallback-default vs explicit nil check | Minor | Calendar vs Email skills |
| A4 | QuantumLoader reload does full rescan; may need incremental API at scale | Future | `quantum_loader.ex:59` |
| A5 | `resolve_workflows_dir/0` duplicated in 5 modules | Minor | Multiple workflow files |
| A6 | `parse_limit/1` duplicated across 4 skill domains | Future | Multiple skill files |

**Blocking**: 0
**Minor**: 3 (A1, A3, A5)
**Future**: 3 (A2, A4, A6)

---

## Recommendation

**Approve.** The architecture is sound, follows established patterns, and introduces no new anti-patterns. The three minor findings (A1, A3, A5) are quality-of-life improvements that could be addressed in a follow-up refactoring pass but do not justify blocking this PR. The workflow system's Quantum-to-Oban bridge is well-designed with correct supervision ordering and clear separation of concerns.
