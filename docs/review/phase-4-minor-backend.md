# Phase 4 Backend Implementation Review

**Reviewer**: Backend Coder (implementation quality)
**PR**: #9 (feature/phase-4-google-skills)
**Commit reviewed**: 6938d5a (minor peer-review fixes)

---

## 1. resolve_path/1 — Path Traversal Fix

**File**: `lib/assistant/scheduler/workflow_worker.ex:104-117`

### Assessment: Sound, with one Minor caveat

The implementation uses a two-layer defense:

1. **Early reject** (line 105): Blocks absolute paths and paths containing `..` literal.
2. **Post-expand boundary check** (lines 109-113): Joins the path under `workflows_dir`, calls `Path.expand/1` to canonicalize, then verifies the result starts with the expanded `workflows_dir`.

The `..` literal check on line 105 is defense-in-depth (not the only layer), so a path like `foo/../../etc/passwd` is caught by the `String.contains?(path, "..")` check before it even reaches the join + expand logic. Good.

`Path.expand/1` resolves `..` segments and `~` expansion. It does **not** resolve symlinks (that would require `File.stat/1` or `:filelib.safe_relative_path/1` on OTP 26+). However, the risk is limited: an attacker would need to plant a symlink inside `priv/workflows/` to escape the boundary, and if they have write access there, they already have broader access.

**Finding [Minor]**: `Path.expand/1` does not follow symlinks. A symlink `priv/workflows/evil -> /etc/` would bypass the prefix check because `Path.expand("priv/workflows/evil/passwd")` still starts with the workflows dir prefix. However, this requires filesystem write access to the workflows directory, making it a low-risk concern.

**Finding [Minor]**: The `String.contains?(path, "..")` check would also block a legitimate filename like `report..v2.md`. This is an extremely unlikely workflow name (and would fail the name validation in `create.ex` anyway), so the over-match is negligible.

---

## 2. YAML Injection Validation

**File**: `lib/assistant/skills/workflow/create.ex:167-175`

### Assessment: Adequate for the threat model

The `validate_no_newlines/2` function checks for `\n` and `\r` in `description` and `channel` fields (lines 32-33). The `name` field is separately validated against `~r/^[a-z][a-z0-9_-]*$/` (line 69), which implicitly blocks all special characters including newlines, null bytes, and YAML-breaking characters.

The `prompt` field is intentionally NOT checked for newlines because it goes into the markdown body (after the `---` closing frontmatter fence), not into YAML frontmatter.

The `cron` field is validated via `Crontab.CronExpression.Parser.parse/1` (line 80), which rejects anything not matching cron syntax -- effectively blocking injection characters.

**Finding [Minor]**: Null bytes (`\0`) are not checked in `description` or `channel`. A null byte in a YAML string value could cause parser misbehavior in some YAML implementations. Practically, null bytes in user input from an LLM agent conversation are extremely unlikely, and Elixir's `File.write!/2` would write the null byte verbatim without truncation (unlike C-based systems). This is a theoretical hardening improvement, not a current vulnerability.

**Finding [Minor]**: The `build_content/1` function (line 105) uses `~s(description: "#{flags["description"]}")` to build YAML. If `description` contains a double quote (`"`), it would break the YAML string quoting. The newline check prevents multi-line injection, but a value like `My "great" workflow` would produce `description: "My "great" workflow"` which is invalid YAML. This likely gets parsed fine by most YAML readers (they may stop at the first closing quote), but it is technically malformed.

---

## 3. Email.Helpers Public API Usage

**File**: `lib/assistant/skills/email/helpers.ex`

### Assessment: Correct at all call sites, one missed cleanup

All four target files use `Helpers.*` correctly:
- **send.ex**: `Helpers.has_newlines?/1` (lines 57, 60, 63), `Helpers.truncate_log/1` (line 78) -- correct.
- **draft.ex**: `Helpers.has_newlines?/1` (lines 57, 60, 63), `Helpers.truncate_log/1` (line 78) -- correct.
- **list.ex**: `Helpers.parse_limit/1` (line 35), `Helpers.full_mode?/1` (line 37), `Helpers.truncate/2` (line 82) -- correct.
- **search.ex**: `Helpers.parse_limit/1` (line 35), `Helpers.full_mode?/1` (line 37), `Helpers.truncate/2` (lines 69, 72) -- correct.

**Finding [Minor]**: `read.ex:86-88` still has a private `truncate_log/1` function that duplicates `Helpers.truncate_log/1`. The `read.ex` version also handles `nil` input (returns `"(none)"`), which the Helpers version does not. This was likely missed during the dedup pass because `read.ex` was not in the original file list for the dedup task. Not blocking since `read.ex` works correctly, but violates DRY.

---

## 4. Workflow.Helpers Alias Usage

**File**: `lib/assistant/skills/workflow/helpers.ex`

### Assessment: Complete migration

All 5 callers properly alias and use `Helpers.resolve_workflows_dir()`:
- **create.ex:26** — `alias Assistant.Skills.Workflow.Helpers`, uses at line 178.
- **list.ex:23** — `alias Assistant.Skills.Workflow.Helpers`, uses at line 27.
- **run.ex:24** — `alias Assistant.Skills.Workflow.Helpers`, uses at line 79.
- **cancel.ex:22** — `alias Assistant.Skills.Workflow.Helpers`, uses at line 103.
- **workflow_worker.ex:48** — `alias Assistant.Skills.Workflow.Helpers`, uses at line 108.

`quantum_loader.ex:35` also aliases and uses `Helpers.resolve_workflows_dir()` at line 96.

No leftover `@workflows_dir` module attributes remain in any caller. Only `helpers.ex` itself has the attribute. Clean.

**Finding**: None. Migration is complete.

**Observation [Future]**: `build.ex` uses `@skills_dir` (pointing to `priv/skills/`) which is a different directory. It does not need `Helpers.resolve_workflows_dir()` -- this is correct by design.

---

## 5. Calendar Nil-Check / with-case Refactor

**Files**: `lib/assistant/skills/calendar/create.ex`, `update.ex`, `list.ex`

### Assessment: Correct behavior preservation

The calendar files use a `cond`-based validation pattern (not `with`/`case`) for `build_params/1`:
- **create.ex:63-81**: Guards against nil/empty `title`, `start`, `end`, then builds params map with `maybe_put/3`. All paths return `{:ok, params}` or `{:error, message}`.
- **update.ex:61-69**: No validation beyond event_id (checked in `execute/2`). Builds a sparse map with `maybe_put/3`. If all flags are nil, sends an empty map -- the Calendar API client is expected to handle this.
- **list.ex:63-84**: `build_opts/1` uses `cond` to route between date, from/to range, and no filter. The `normalize_date_range/1` returns `{:ok, min, max}` or `{:error, msg}`, and the `case` on line 70 handles both. Complete.

**Finding**: None. Behavior is consistent and result patterns are complete.

---

## 6. parse_attendees Empty List

**File**: `lib/assistant/skills/calendar/create.ex:92-98` and `update.ex:81-87`

### Assessment: Functional, idiomatic enough

```elixir
defp parse_attendees(str) do
  result = str |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))
  if result == [], do: nil, else: result
end
```

The `if result == []` pattern is straightforward and readable. Alternatives like `Enum.empty?/1` or a guard (`when result == []`) are stylistic preferences, not improvements. Using a `case` with pattern matching (`case result do [] -> nil; r -> r end`) would be marginally more "Elixir-y" but functionally identical.

**Finding [Minor]**: The `parse_attendees/1` function is duplicated identically between `create.ex:95-98` and `update.ex:84-87`. Same for `maybe_put/3` (create.ex:100-101 and update.ex:89-90) and `normalize_datetime/1` (create.ex:84-90 and update.ex:71-79). These three functions could be extracted into a shared `Calendar.Helpers` module, mirroring the Email.Helpers and Workflow.Helpers pattern.

---

## Summary

| # | File | Finding | Severity | Description |
|---|------|---------|----------|-------------|
| 1 | workflow_worker.ex | Symlink bypass | Minor | `Path.expand/1` doesn't resolve symlinks; requires attacker write access to exploit |
| 2 | workflow_worker.ex | Over-broad `..` check | Minor | Blocks filenames containing `..` (e.g. `report..v2.md`); mitigated by name validation elsewhere |
| 3 | workflow/create.ex | Null byte unchecked | Minor | `\0` not in newline check for description/channel; very low risk from LLM agent input |
| 4 | workflow/create.ex | YAML quote escape | Minor | Double quotes in description/channel produce malformed YAML string literals |
| 5 | email/read.ex | Duplicate truncate_log | Minor | Private `truncate_log/1` duplicates `Helpers.truncate_log/1`; missed during dedup |
| 6 | calendar/ | Shared helpers opportunity | Future | `parse_attendees/1`, `maybe_put/3`, `normalize_datetime/1` duplicated between create.ex and update.ex |

**Blocking findings**: 0
**Minor findings**: 5
**Future findings**: 1

Overall the implementation is solid. Security fixes are correctly layered, helpers extraction is clean and complete (with one missed file), and the calendar refactor preserves all existing behavior. No blocking issues.
