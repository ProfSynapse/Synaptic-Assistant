# Architect Review: Fix Commit (6938d5a)

**Reviewer**: pact-architect
**Scope**: Architectural review of minor fix commit on Phase 4 PR #9
**Date**: 2026-02-19

---

## 1. Email.Helpers Module Design

**Location**: `lib/assistant/skills/email/helpers.ex`

### 1a. `@moduledoc false` appropriateness — **Minor**

`@moduledoc false` hides the module from ExDoc. This is appropriate for purely internal utility modules that callers discover by reading source, not documentation. However, `Email.Helpers` defines a public API (`parse_limit/1`, `full_mode?/1`, `has_newlines?/1`, `truncate/2`, `truncate_log/1`) consumed by four sibling modules. Using `@moduledoc false` is acceptable for now, but if the Helpers surface expands or external modules begin consuming it, a proper `@moduledoc` should be added.

**Verdict**: Acceptable. Consistent with Elixir convention for domain-internal helpers.

### 1b. `@default_limit` / `@max_limit` as module attributes vs. function args — **Minor**

The constants are baked into `Email.Helpers` at compile time:

```elixir
@default_limit 10
@max_limit 50
```

This is the right call for this codebase. The alternative (passing them as arguments) would push configuration responsibility onto every caller, violating the DRY principle and adding noise to four call sites. If a future skill domain needs different limits, it can define its own helpers or override via a separate module — but for email, a single default is correct.

**Note**: Calendar's `list.ex` still has its own private `parse_limit/1` with identical `@default_limit 10` / `@max_limit 50` constants (lines 117-127). This is not a regression from the fix commit — it predates it — but it represents a missed opportunity. See Future finding F1.

### 1c. Function scoping (public vs. private) — **No issue**

All five functions are correctly `def` (public). They are called from sibling modules (`send.ex`, `draft.ex`, `list.ex`, `search.ex`), so they must be public. No private functions exist in the module. No functions are unnecessarily exposed.

**Verdict**: Correct scoping.

### 1d. Alias consistency — **No issue**

All four consumers use the identical pattern:

```elixir
alias Assistant.Skills.Email.Helpers
```

And call via `Helpers.parse_limit(...)`, `Helpers.has_newlines?(...)`, etc. Consistent throughout.

---

## 2. Workflow.Helpers Module Design

**Location**: `lib/assistant/skills/workflow/helpers.ex`

### 2a. Namespace placement — **No issue**

The module is `Assistant.Skills.Workflow.Helpers`, placed under `lib/assistant/skills/workflow/helpers.ex`. This is correct. The function `resolve_workflows_dir/0` is consumed by:

- `Assistant.Skills.Workflow.Create` (skill handler)
- `Assistant.Skills.Workflow.List` (skill handler)
- `Assistant.Skills.Workflow.Run` (skill handler)
- `Assistant.Skills.Workflow.Cancel` (skill handler)
- `Assistant.Scheduler.QuantumLoader` (scheduler)
- `Assistant.Scheduler.WorkflowWorker` (Oban worker)

The question raised was whether it should be `Assistant.Workflow.Helpers` instead. No: there is no top-level `Assistant.Workflow` namespace in this codebase. Workflow skills live under `Assistant.Skills.Workflow.*`, and the schedulers consume them as cross-cutting infrastructure. The current namespace `Assistant.Skills.Workflow.Helpers` is the most natural home.

The scheduler modules (`QuantumLoader`, `WorkflowWorker`) reaching into `Assistant.Skills.Workflow.Helpers` does create a dependency arrow from scheduler -> skills. This is acceptable because the helpers module is a thin config-resolution utility, not business logic. If the dependency were reversed (skills depending on scheduler internals), that would be a concern.

**Verdict**: Correct namespace. Dependency direction is acceptable.

### 2b. Alias consistency — **No issue**

All six consumers use:

```elixir
alias Assistant.Skills.Workflow.Helpers
```

And call `Helpers.resolve_workflows_dir()`. Consistent throughout.

### 2c. `@moduledoc` vs `@moduledoc false` — **No issue**

Unlike `Email.Helpers`, `Workflow.Helpers` has a proper `@moduledoc` with a `@doc` on `resolve_workflows_dir/0`. This is slightly inconsistent with `Email.Helpers` (`@moduledoc false`), but not a problem — the Workflow module has a smaller surface (one function) that is more likely to be discovered by scheduler authors outside the skills domain, making documentation more valuable.

### 2d. `workflow/build.ex` not using Helpers — **Minor**

`workflow/build.ex` writes to `priv/skills/` (a different directory) using `@skills_dir`, not `priv/workflows/`. It does not need `resolve_workflows_dir/0`. This is correct — `build.ex` creates meta-skill definitions, not cron-scheduled workflow prompt files. No architectural issue here.

---

## 3. Calendar Integration Injection Pattern

**Location**: `lib/assistant/skills/calendar/{create,list,update}.ex`

### 3a. Pattern change to nil-check — **No issue**

All three calendar skills now use:

```elixir
case Map.get(context.integrations, :calendar) do
  nil -> {:ok, %Result{status: :error, content: "Google Calendar integration not configured."}}
  calendar -> # proceed with calendar module
end
```

This matches the email skills' established pattern for `:gmail`:

```elixir
case Map.get(context.integrations, :gmail) do
  nil -> {:ok, %Result{status: :error, content: "Gmail integration not configured."}}
  gmail -> # proceed with gmail module
end
```

The prior approach used a module-level `@calendar_mod` with `Application.compile_env` fallback. The nil-check pattern is architecturally superior for this codebase because:

1. **Consistency**: All skill domains (email, calendar) now follow the same injection pattern
2. **Testability**: Test contexts can inject mocks via the `context.integrations` map without compile-time configuration
3. **Explicit failure**: Missing integration produces a clear user-facing error rather than a silent fallback or crash
4. **Runtime flexibility**: Integrations can be conditionally available per-user or per-session

### 3b. "Works out of the box" concern — **No issue**

The concern was whether requiring explicit `:calendar` injection breaks the module's usability. It does not. The skill handlers are never called directly — they are invoked through the skill execution pipeline, which is responsible for building the `context` struct. The context builder (upstream) decides which integrations are available. Individual skill handlers simply receive and validate what they get.

This is correct Dependency Inversion: handlers depend on the abstraction (the context contract), not on concrete module references.

---

## 4. Architectural Regressions

### 4a. Path traversal fix in `workflow_worker.ex` — **No issue**

The `resolve_path/1` function (lines 104-117) implements defense-in-depth:
1. Rejects absolute paths and `..` components early
2. Joins relative path to the workflows directory
3. Verifies the resolved path is still within the workflows directory after `Path.expand/1`

This is structurally sound. The Helpers module is correctly used for the base directory resolution.

### 4b. YAML injection prevention in `workflow/create.ex` — **No issue**

The `validate_no_newlines/2` function (lines 167-175) prevents newline injection in `description` and `channel` fields that are interpolated into YAML frontmatter. Combined with the existing `validate_name/1` regex check (line 69: `~r/^[a-z][a-z0-9_-]*$/`), the attack surface for YAML injection via `create.ex` is adequately mitigated.

### 4c. `parse_attendees` empty-list fix — **No issue**

The fix in both `create.ex:97` and `update.ex:86`:

```elixir
if result == [], do: nil, else: result
```

Prevents passing an empty list to the Calendar API when the attendees string resolves to all-blank entries (e.g., `","` or `" , "`). Returning `nil` causes `maybe_put/3` to skip the key entirely. Correct behavior.

### 4d. `require Logger` in `email/search.ex` — **No issue**

Trivial fix. No architectural impact.

### 4e. Gmail `list_messages` default arg — **No issue**

Trivial fix. No architectural impact.

---

## 5. Summary of Findings

| ID | Finding | Classification | Location |
|----|---------|---------------|----------|
| F1 | Calendar `list.ex` has its own `parse_limit/1` identical to `Email.Helpers.parse_limit/1`. A shared `Skills.Helpers` or `Calendar.Helpers` would eliminate this. Same for `normalize_datetime/1`, `parse_attendees/1`, and `maybe_put/3` duplicated across calendar create/update. | **Future** | `calendar/list.ex:117-127`, `calendar/create.ex:84-101`, `calendar/update.ex:71-90` |
| F2 | `Email.Helpers` uses `@moduledoc false` while `Workflow.Helpers` uses `@moduledoc`. Minor inconsistency in helpers documentation strategy. | **Future** | `email/helpers.ex:13`, `workflow/helpers.ex:14` |
| F3 | `files/search.ex` (lines 166-176) has its own private `parse_limit/1` with the same `@default_limit 10` / `@max_limit 50`. If a project-wide Helpers module is introduced (F1), this could be consolidated. | **Future** | `files/search.ex:166-176` |

**No Blocking findings.**
**No Minor-in-this-PR findings** (the existing minor items were addressed correctly by the fix commit).

---

## 6. Architectural Verdict

The fix commit is architecturally sound. The two new Helpers modules correctly centralize previously duplicated logic. The calendar injection pattern change establishes cross-domain consistency. The security fixes (path traversal, YAML injection) are structurally correct. No regressions introduced.

The remaining duplication across calendar and files domains (F1, F3) is a natural candidate for a future consolidation pass but does not warrant blocking this PR.
