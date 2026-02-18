# Phase 4 Test Review — PR #9

> Reviewer: pact-test-engineer
> Date: 2026-02-18
> Risk Tier: HIGH (new integration clients, mutating skills, scheduled job system)
> Scope: Gmail/Calendar skills, Workflow skills, QuantumLoader, WorkflowWorker, Integrations.Registry

---

## Executive Summary

Phase 4 adds **20 new source files** across four domains (email, calendar, workflow, scheduler) with **zero test files**. The existing test suite has no coverage for any Phase 4 code. The integration client pattern (mock injection via `context.integrations`) is well-designed for testability and already proven by `files/search_test.exs`. However, the complete absence of tests is a significant gap for code that includes mutating operations (email send, calendar create/update, workflow file creation/deletion).

---

## 1. Test Coverage Analysis

### Current State: No Phase 4 Tests

| Domain | Source Files | Test Files | Coverage |
|--------|-------------|------------|----------|
| Email skills | 5 (`send.ex`, `read.ex`, `search.ex`, `list.ex`, `draft.ex`) | 0 | 0% |
| Calendar skills | 3 (`create.ex`, `list.ex`, `update.ex`) | 0 | 0% |
| Workflow skills | 5 (`create.ex`, `run.ex`, `list.ex`, `cancel.ex`, `build.ex`) | 0 | 0% |
| Gmail client | 1 (`gmail.ex`) | 0 | 0% |
| Calendar client | 1 (`calendar.ex`) | 0 | 0% |
| Integrations.Registry | 1 (`registry.ex`) | 0 | 0% |
| QuantumLoader | 1 (`quantum_loader.ex`) | 0 | 0% |
| WorkflowWorker | 1 (`workflow_worker.ex`) | 0 | 0% |
| Context changes | modified (`context.ex`, `loop_runner.ex`, `sub_agent.ex`, `agent.ex`) | 0 | 0% |
| **Total** | **18 new + 4 modified** | **0** | **0%** |

### Existing Test Patterns (Reference)

The project has a well-established mock injection pattern in `test/assistant/skills/files/search_test.exs`:

- Define a `MockDrive` module inline in the test file
- Inject it via `%Context{integrations: %{drive: MockDrive}}`
- Use `Process.get/put` for per-test response control
- Use `send(self(), ...)` + `assert_received` to verify call arguments

This pattern directly applies to all email and calendar skill tests.

The `CompactionWorkerTest` shows the Oban worker testing pattern:
- Test `new/1` changeset validity, args, queue, and uniqueness
- Use `Code.ensure_loaded?` for module availability checks

---

## 2. Testability Assessment

### 2.1 Email Skills — Good Testability (Blocking: no tests)

**Pattern**: All 5 email skills use `Map.get(context.integrations, :gmail, Gmail)` or `Map.get(context.integrations, :gmail)`. This allows clean mock injection.

**Observation**: `email.send` and `email.draft` use the two-level guard pattern (`Map.get` returns `nil` -> error), while `email.search`, `email.list`, and `email.read` do the same. All are testable without external dependencies.

**Test cases needed**:

| Skill | Priority | Key Test Cases |
|-------|----------|---------------|
| `email.send` | CRITICAL | Happy path, missing --to/--subject/--body, newline injection in headers, Gmail API error, `:header_injection` error |
| `email.draft` | HIGH | Happy path, missing params, newline injection, API error |
| `email.search` | HIGH | Empty results, multiple results, --full mode, query building with all flag combos, --unread flag, limit parsing |
| `email.read` | HIGH | Single ID, comma-separated IDs, missing --id, :not_found error, mixed success/failure |
| `email.list` | HIGH | Happy path, label filtering, --unread, --full mode, limit clamping |

**Finding B1** (Blocking): `email.send` is a mutating skill that sends real emails. Zero test coverage for parameter validation and header injection prevention is a significant gap for a CRITICAL-risk operation.

**Finding B2** (Blocking): `email.draft` has identical validation logic to `email.send` but is a separate copy. Both need independent tests to ensure the duplicated validation stays in sync.

### 2.2 Calendar Skills — Good Testability (Blocking: no tests)

**Pattern**: All 3 calendar skills use `Map.get(context.integrations, :calendar, Calendar)`. Same mock injection pattern as email.

**Test cases needed**:

| Skill | Priority | Key Test Cases |
|-------|----------|---------------|
| `calendar.create` | CRITICAL | Happy path, missing --title/--start/--end, datetime normalization (`YYYY-MM-DD HH:MM` -> RFC 3339), attendee parsing, API error |
| `calendar.list` | HIGH | Empty results, --date validation (YYYY-MM-DD), --from/--to range, limit clamping, invalid date format error |
| `calendar.update` | HIGH | Happy path, missing --id, sparse update (only changed fields), API error |

**Finding B3** (Blocking): `calendar.create` is a mutating skill that creates real calendar events. The `normalize_datetime/1` function silently converts `"2026-02-19 09:00"` to `"2026-02-19T09:00:00Z"` (hardcoded UTC). No test verifies this normalization, and no test verifies what happens with malformed datetime strings that don't match the regex but aren't valid RFC 3339 either.

### 2.3 Gmail Client (`gmail.ex`) — Moderate Testability (Blocking: no tests)

The Gmail client module has several pure/near-pure functions worth unit testing:

| Function | Testability | Notes |
|----------|------------|-------|
| `validate_headers/3` | Pure function | Testable directly — critical security function |
| `build_rfc2822/4` | Pure function | Testable directly — email format construction |
| `base64url_encode/1` | Pure function | Testable directly |
| `normalize_message/1` | Pure function (takes struct) | Testable with mock structs |
| `extract_headers/1` | Pure function | Testable with mock structs |
| `extract_body/1` | Pure function | Multiple clauses, needs coverage for each MIME type pattern |
| `base64url_decode/1` | Pure function | Testable directly, includes padding logic |
| `pad_base64/1` | Pure function | 4 branches (rem 0, 2, 3, other) |

**Finding B4** (Blocking): `validate_headers/3`, `build_rfc2822/4`, and `base64url_encode/1` are security-critical private functions with zero test coverage. The header injection prevention (`validate_headers`) is the primary defense against RFC 2822 header injection attacks. These are pure functions and trivially testable — they just need to be tested.

**Finding M1** (Minor): `base64url_encode/1` uses a chain of `String.replace` calls instead of Elixir's built-in `Base.url_encode64/2` with `padding: false`. The custom implementation works but the standard library function is more robust. Not a test issue per se, but testing would reveal whether edge cases (empty string, binary with all special chars) are handled correctly.

**Finding M2** (Minor): All Gmail client functions are private (`defp`). To test `validate_headers`, `build_rfc2822`, etc., either:
- Extract them as public functions in a helper module (recommended for security-critical code)
- Test them indirectly through `send_message/4` (acceptable but less precise)
- Use `send_message/4` with a mock connection to test the full pipeline

### 2.4 Calendar Client (`calendar.ex`) — Moderate Testability (Minor: no tests)

Similar to Gmail client. Pure helper functions are testable:

| Function | Notes |
|----------|-------|
| `build_event_struct/1` | Constructs `%Model.Event{}` from params |
| `build_event_datetime/1` | Hardcodes `timeZone: "UTC"` (see Finding M3) |
| `build_attendees/1` | Handles nil, empty, and list |
| `normalize_event/1` | Struct-to-map conversion |
| `merge_event_updates/2` | Selective field update |

**Finding M3** (Minor): `build_event_datetime/1` hardcodes `timeZone: "UTC"`. The `Context` struct has a `:timezone` field, but it is never used by the Calendar client. Tests should verify the timezone behavior and document this as intentional or a gap.

### 2.5 Workflow Skills — Moderate Testability (Blocking: no tests)

Workflow skills interact with the filesystem (`File.exists?`, `File.write!`, `File.rm`) and OTP processes (`Oban.insert`, `QuantumLoader.reload`, `Scheduler.delete_job`). These are harder to test but still feasible.

| Skill | Priority | Key Test Cases | Testability Concern |
|-------|----------|---------------|---------------------|
| `workflow.create` | HIGH | Name validation regex, cron validation, file conflict check, frontmatter generation, QuantumLoader reload | Writes to filesystem; needs temp dir |
| `workflow.run` | HIGH | Happy path, missing --name, workflow not found, Oban insert error | Requires Oban (or mock) |
| `workflow.list` | MEDIUM | Empty dir, multiple workflows, parse error handling | Reads filesystem |
| `workflow.cancel` | HIGH | Happy path, missing --name, not found, --delete flag, file deletion error | Writes/deletes filesystem + Quantum |
| `workflow.build` | LOW | Legacy Phase 1 stub, lower priority | Registry dependency |

**Finding B5** (Blocking): `workflow.create` writes files to disk based on user input (`flags["name"]`). The `validate_name/1` function uses `~r/^[a-z][a-z0-9_-]*$/` but the `workflow_path/1` function joins this directly into a file path. While the regex prevents path traversal (no `/` or `..` characters allowed), there are no tests verifying this security boundary.

**Finding B6** (Blocking): `workflow.cancel` with `--delete true` permanently removes files from disk. This destructive operation has zero test coverage.

**Testing approach for workflow skills**:
- Use a temporary directory via `System.tmp_dir!/0` + unique subdirectory
- Set `Application.put_env(:assistant, :workflows_dir, tmp_dir)` in test setup
- Clean up in `on_exit` callback
- For Oban interactions: either use `Oban.Testing` helpers or mock at the skill level

### 2.6 QuantumLoader — Moderate Testability (Blocking: no tests)

**Finding B7** (Blocking): `QuantumLoader` is a GenServer that:
1. Scans a directory for `.md` files
2. Parses YAML frontmatter for `cron:` fields
3. Validates cron expressions via `Crontab.CronExpression.Parser`
4. Registers Quantum jobs via `Assistant.Scheduler.add_job/1`
5. Each job's task is a closure that inserts an Oban job

This is the bridge between cron scheduling and job execution. Zero tests.

**Testing approach**:
- Unit test `register_if_scheduled/1` logic by creating temp workflow files with/without `cron:` fields
- Test `workflow_job_name/1` — the `String.to_atom` call is concerning for atom exhaustion if called with arbitrary user input (see Finding M4)
- Test reload behavior (removes old jobs, adds new ones)
- Mock or stub `Assistant.Scheduler` for job registration verification

**Finding M4** (Minor): `workflow_job_name/1` calls `String.to_atom("workflow_#{safe_name}")`. While the regex sanitization limits the character set, atoms are never garbage collected. If workflows are created and deleted frequently, this could leak atoms over time. Test should verify the sanitization and document the atom creation.

### 2.7 WorkflowWorker — Moderate Testability (Blocking: no tests)

**Finding B8** (Blocking): `WorkflowWorker` is an Oban worker with:
- `perform/1` that reads a file, parses frontmatter, and optionally posts to Google Chat
- `resolve_path/1` that handles absolute and relative paths
- `execute_prompt/2` is currently a stub (TODO comment)
- `maybe_post_to_channel/3` calls `Google.Chat.send_message/2` — a real external call

The missing `workflow_path` args clause correctly returns `{:error, :missing_workflow_path}` — good defensive coding, but untested.

**Testing approach** (following `CompactionWorkerTest` pattern):
- Test `new/1` changeset: queue is `:scheduled`, max_attempts is 3, uniqueness config
- Test `perform/1` with a temp workflow file (happy path)
- Test `perform/1` with missing file (`:workflow_not_found`)
- Test `perform/1` with missing `workflow_path` key
- Mock `Google.Chat.send_message/2` for channel posting tests

### 2.8 Integrations.Registry — Trivial (Minor: no tests)

**Finding M5** (Minor): `Integrations.Registry.default_integrations/0` returns a static map. A simple test verifying the keys (`:drive`, `:gmail`, `:calendar`) and module values would be sufficient. Low priority but easy to add.

### 2.9 Context/Integration Wiring — Minor gaps

The PR modifies `loop_runner.ex`, `sub_agent.ex`, and `agent.ex` to add `integrations: Assistant.Integrations.Registry.default_integrations()`. Existing tests for these modules may need updates to account for the new field.

**Finding M6** (Minor): No existing test verifies that the `integrations` field is populated in `LoopRunner.build_skill_context/1`, `SubAgent` context building, or `MemoryAgent` context building. While the wiring is straightforward, a regression test would catch accidental removal.

---

## 3. Recommended Test Plan

### Priority 1: Blocking — Must Have Before Merge

These tests cover security-critical and mutating operations.

#### 3.1 Email Skill Tests

**File**: `test/assistant/skills/email/send_test.exs`
```
- MockGmail module (inline, following search_test.exs pattern)
- Happy path: valid params -> sends, returns message ID
- Missing --to, --subject, --body -> error result
- Newline injection in --to -> error
- Newline injection in --subject -> error
- Newline injection in --cc -> error
- Gmail API returns {:error, :header_injection} -> error result
- Gmail API returns {:error, reason} -> error result
- No gmail integration -> "not configured" error
- With --cc option -> passes cc to gmail.send_message
```

**File**: `test/assistant/skills/email/draft_test.exs`
- Same structure as send_test.exs but calls `create_draft` instead

**File**: `test/assistant/skills/email/search_test.exs`
```
- Query building: --query, --from, --to, --after, --before, --unread combinations
- Empty results -> "No messages found"
- Multiple results -> formatted output with count
- --full mode -> includes body content
- Limit parsing: default, custom, clamped to max, non-numeric
- Gmail API error -> error result
- No gmail integration -> "not configured" error
```

**File**: `test/assistant/skills/email/read_test.exs`
```
- Single ID -> formatted message
- Comma-separated IDs -> multiple messages with dividers
- Missing --id -> error
- Message not found -> error message in output
- Mixed results (some succeed, some fail) -> partial output
```

**File**: `test/assistant/skills/email/list_test.exs`
```
- Happy path with label
- --unread flag
- --full mode
- Limit clamping
- Empty inbox
```

#### 3.2 Calendar Skill Tests

**File**: `test/assistant/skills/calendar/create_test.exs`
```
- Happy path with title, start, end
- Missing --title, --start, --end -> error
- Datetime normalization: "2026-02-19 09:00" -> "2026-02-19T09:00:00Z"
- Already-RFC3339 datetime passed through unchanged
- Attendee parsing: comma-separated, with spaces, empty string
- Optional fields: --description, --location
- Calendar API error -> error result
- Custom --calendar ID
```

**File**: `test/assistant/skills/calendar/list_test.exs`
```
- Empty results
- --date flag -> time_min/time_max range
- Invalid date format -> error
- --from/--to range
- Limit parsing
```

**File**: `test/assistant/skills/calendar/update_test.exs`
```
- Missing --id -> error
- Sparse update (only title changed)
- Full update (all fields)
- Calendar API error
```

#### 3.3 WorkflowWorker Test

**File**: `test/assistant/scheduler/workers/workflow_worker_test.exs`
```
- new/1 changeset: queue is "scheduled", max_attempts 3, valid
- new/1 changeset: args include workflow_path
- perform/1 with valid temp workflow file -> :ok
- perform/1 with missing file -> {:error, {:workflow_not_found, path}}
- perform/1 with missing workflow_path arg -> {:error, :missing_workflow_path}
```

#### 3.4 Workflow Skill Tests (filesystem-touching)

**File**: `test/assistant/skills/workflow/create_test.exs`
```
- Happy path with name, description, prompt
- Missing required flags -> error
- Invalid name (uppercase, special chars) -> error
- Invalid cron expression -> error
- Duplicate name -> conflict error
- Generated file contains correct frontmatter
- With cron + channel -> included in frontmatter
```

**File**: `test/assistant/skills/workflow/cancel_test.exs`
```
- Happy path -> job removed, file preserved
- --delete flag -> file removed from disk
- Missing --name -> error
- Workflow not found -> error
```

### Priority 2: Minor — Should Have

#### 3.5 Gmail Client Pure Function Tests

**File**: `test/assistant/integrations/google/gmail_test.exs`

Test the pure functions indirectly through `send_message/4`:
```
- Header injection with \r\n in to -> {:error, :header_injection}
- Header injection with \n in subject -> {:error, :header_injection}
- Valid headers -> proceeds to send
```

If pure functions are extracted as public:
```
- base64url_encode roundtrip
- build_rfc2822 format verification
- extract_body with various MIME structures
- pad_base64 with all remainder cases
```

#### 3.6 Integrations.Registry Test

**File**: `test/assistant/integrations/registry_test.exs`
```
- default_integrations/0 returns map with :drive, :gmail, :calendar keys
- Each value is the expected module
```

#### 3.7 QuantumLoader Test

**File**: `test/assistant/scheduler/quantum_loader_test.exs`
```
- Loads workflows with cron: field
- Skips workflows without cron: field
- Skips files with invalid cron expressions
- Handles missing workflows directory
- reload/0 removes old jobs and re-scans
```

### Priority 3: Future

- `workflow.list` and `workflow.run` tests
- `workflow.build` (Phase 1 stub, low priority)
- Calendar client unit tests for `normalize_event/1`, `merge_event_updates/2`
- Integration tests with `Oban.Testing` for full workflow execution pipeline
- `email.list` resolve_messages error accumulation behavior

---

## 4. Findings Summary

### Blocking

| ID | Component | Finding | Severity |
|----|-----------|---------|----------|
| B1 | `email.send` | Mutating skill with zero test coverage for param validation and header injection prevention | Blocking |
| B2 | `email.draft` | Duplicated validation logic with `email.send`, both untested | Blocking |
| B3 | `calendar.create` | Mutating skill with untested datetime normalization; hardcoded UTC timezone | Blocking |
| B4 | `gmail.ex` | Security-critical `validate_headers/3` and `build_rfc2822/4` have zero test coverage | Blocking |
| B5 | `workflow.create` | Filesystem-writing skill with untested name validation security boundary | Blocking |
| B6 | `workflow.cancel` | Destructive file deletion operation with zero test coverage | Blocking |
| B7 | `quantum_loader.ex` | GenServer bridging cron scheduling to Oban job execution, untested | Blocking |
| B8 | `workflow_worker.ex` | Oban worker with file I/O and external Chat posting, untested | Blocking |

### Minor

| ID | Component | Finding | Severity |
|----|-----------|---------|----------|
| M1 | `gmail.ex` | `base64url_encode/1` reimplements `Base.url_encode64/2` | Minor |
| M2 | `gmail.ex` | Security functions are private — harder to test directly | Minor |
| M3 | `calendar.ex` | `build_event_datetime/1` hardcodes UTC, ignores `Context.timezone` | Minor |
| M4 | `quantum_loader.ex` | `String.to_atom` in `workflow_job_name/1` — atom exhaustion risk | Minor |
| M5 | `registry.ex` | No test for `default_integrations/0` | Minor |
| M6 | Context wiring | No regression test for `integrations` field in context builders | Minor |

### Future

| ID | Component | Finding | Severity |
|----|-----------|---------|----------|
| F1 | `workflow_worker.ex` | `execute_prompt/2` is a stub (TODO) — needs tests when wired to agent | Future |
| F2 | `calendar.ex` | `Context.timezone` integration for event creation | Future |
| F3 | `email/draft.ex` + `email/send.ex` | Validation logic duplication — consider shared validator module | Future |

---

## 5. Mock Injection Pattern Verification

The existing `files/search_test.exs` pattern works directly for email and calendar skills:

```elixir
# Email skills use:
gmail = Map.get(context.integrations, :gmail)
# -> Inject via %Context{integrations: %{gmail: MockGmail}}

# Calendar skills use:
calendar = Map.get(context.integrations, :calendar, Calendar)
# -> Inject via %Context{integrations: %{calendar: MockCalendar}}
```

Both patterns support the inline mock module approach. The `email.send`, `email.draft`, and `email.read` skills use the nil-check pattern (return "not configured" error when `nil`), which also needs test coverage.

The `calendar.*` skills use the default-module pattern (`Map.get(..., Calendar)`), meaning they will fall through to the real Calendar module if no mock is injected. This is the same pattern as `files.search` and works well.

---

## 6. Signal Output

```
Risk Tier: HIGH
Signal: RED
Coverage: 0% for all Phase 4 code
Uncertainty Coverage: N/A (no HIGH areas flagged in handoff)
Findings: 8 blocking items — zero test files for 18 new source files including
  mutating skills (email send, calendar create/update), filesystem operations
  (workflow create/cancel), and scheduler infrastructure (QuantumLoader,
  WorkflowWorker). Security-critical header injection prevention is untested.
  All code follows the established mock injection pattern and IS testable.
```

**Recommendation**: Route back to test engineer (or coders with test hat) to implement Priority 1 tests before merge. The code quality is good and the testability patterns are well-established — the gap is purely that tests were not written, not that the code is untestable.

---

## 7. Test Implementation Notes

### MockGmail Pattern (for all email skill tests)

```elixir
defmodule MockGmail do
  def send_message(to, subject, body, opts) do
    send(self(), {:gmail_send, to, subject, body, opts})
    Process.get(:mock_gmail_response, {:ok, %{id: "msg_123", thread_id: "thread_456"}})
  end

  def get_message(id, _user_id \\ "me", _opts \\ []) do
    send(self(), {:gmail_get, id})
    Process.get(:mock_gmail_get_response, {:ok, %{
      id: id, subject: "Test", from: "a@b.com",
      to: "c@d.com", date: "2026-02-18", body: "Hello", snippet: "Hello"
    }})
  end

  def search_messages(query, opts) do
    send(self(), {:gmail_search, query, opts})
    Process.get(:mock_gmail_search_response, {:ok, []})
  end

  def list_messages(user_id, query, opts) do
    send(self(), {:gmail_list, user_id, query, opts})
    Process.get(:mock_gmail_list_response, {:ok, []})
  end

  def create_draft(to, subject, body, opts) do
    send(self(), {:gmail_draft, to, subject, body, opts})
    Process.get(:mock_gmail_draft_response, {:ok, %{id: "draft_123"}})
  end
end
```

### MockCalendar Pattern

```elixir
defmodule MockCalendar do
  def list_events(calendar_id, opts) do
    send(self(), {:cal_list, calendar_id, opts})
    Process.get(:mock_cal_list_response, {:ok, []})
  end

  def create_event(params, calendar_id) do
    send(self(), {:cal_create, params, calendar_id})
    Process.get(:mock_cal_create_response, {:ok, %{
      id: "evt_123", summary: params[:summary],
      html_link: "https://calendar.google.com/event?eid=evt_123"
    }})
  end

  def update_event(event_id, params, calendar_id) do
    send(self(), {:cal_update, event_id, params, calendar_id})
    Process.get(:mock_cal_update_response, {:ok, %{
      id: event_id, summary: params[:summary] || "Updated"
    }})
  end
end
```

### Workflow Test Setup Pattern

```elixir
setup do
  tmp_dir = Path.join(System.tmp_dir!(), "workflow_test_#{:erlang.unique_integer([:positive])}")
  File.mkdir_p!(tmp_dir)
  Application.put_env(:assistant, :workflows_dir, tmp_dir)

  on_exit(fn ->
    Application.delete_env(:assistant, :workflows_dir)
    File.rm_rf!(tmp_dir)
  end)

  %{workflows_dir: tmp_dir}
end
```
