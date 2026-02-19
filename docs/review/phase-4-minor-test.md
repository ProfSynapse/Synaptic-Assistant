# Phase 4 Minor Fix Commit - Test Coverage Review

**Reviewer**: pact-test-engineer
**Commit**: 6938d5a (minor peer-review fixes)
**Risk Tier**: HIGH (security-relevant code: path traversal, YAML injection, header injection dedup)

---

## 1. Email.Helpers Tests

**Status**: No dedicated `helpers_test.exs` exists.

**Analysis**: `Email.Helpers` exposes 5 public functions: `has_newlines?/1`, `truncate_log/1`, `truncate/2`, `parse_limit/1`, and `full_mode?/1`. These were extracted from duplicated code in send, draft, list, and search modules. Coverage assessment:

| Function | Covered By | Assessment |
|----------|-----------|------------|
| `has_newlines?/1` | `send_test.exs` (lines 154-168), `draft_test.exs` (lines 132-155) | Adequately tested via integration: `\r\n`, `\n`, valid strings |
| `truncate_log/1` | Not directly tested | Only used in logging metadata; low observable impact |
| `truncate/2` | Not directly tested | Used in search output formatting; indirectly exercised when search_test checks content |
| `parse_limit/1` | `list_test.exs` (lines 136-158), `search_test.exs` (lines 201-236), `calendar/list_test.exs` (lines 166-201) | Thoroughly tested: default, custom, clamp min/max, non-numeric, integer |
| `full_mode?/1` | `list_test.exs` (line 167), `search_test.exs` (lines 173-194) | Tested: true, false, nil (default) |

**Finding - Minor**: No dedicated `helpers_test.exs` for the new `Email.Helpers` module. The shared functions are exercised through caller tests, but pure-function unit tests would be more precise and would survive refactoring of callers. Specifically, `truncate_log/1` (boundary at 50 bytes) and `truncate/2` (boundary at `max` bytes) have no direct assertions on their output.

**Finding - Minor**: `parse_limit/1` catchall clause `parse_limit(_)` (line 34 of helpers.ex) is not tested with a non-binary, non-integer, non-nil value (e.g., a list or atom). This is covered by callers always passing string/nil, but the function's public API accepts `any()`.

---

## 2. Calendar Nil-Check Regression

**Status**: No regression risk detected.

**Analysis**: The fix changed calendar integration injection from `Map.get(context.integrations, :calendar, Calendar)` (fallback to real module) to a nil-check pattern:

```elixir
case Map.get(context.integrations, :calendar) do
  nil -> {:ok, %Result{status: :error, content: "Google Calendar integration not configured."}}
  calendar -> ...
end
```

This pattern is used identically in `create.ex` (line 27), `update.ex` (line 27), and `list.ex` (line 30).

**Test coverage check**:

| Test File | Mock Injection | No-Integration Test |
|-----------|---------------|---------------------|
| `create_test.exs` | `integrations: %{calendar: MockCalendar}` (line 48) | **None** |
| `update_test.exs` | `integrations: %{calendar: MockCalendar}` (line 47) | **None** |
| `list_test.exs` | `integrations: %{calendar: MockCalendar}` (line 39) | **None** |

All calendar tests inject `MockCalendar` via `integrations: %{calendar: MockCalendar}`, so they never exercise the `nil` branch.

**Finding - Blocking**: `calendar/create_test.exs`, `calendar/update_test.exs`, and `calendar/list_test.exs` have no test for when `:calendar` is absent from `context.integrations`. The email tests all have a "without Gmail integration" section that tests `integrations: %{}` (e.g., `send_test.exs` line 223-231, `list_test.exs` line 192-200). The calendar tests are missing this equivalent coverage.

This is security-relevant because the previous code silently fell back to the real `Calendar` module (which would fail at runtime with Goth/auth errors). The new code returns a clean user error. But the new error path is **untested** in all three calendar handlers.

---

## 3. Path Traversal Tests (WorkflowWorker)

**Status**: No path traversal rejection tests exist.

**Analysis**: `workflow_worker.ex` `resolve_path/1` (lines 104-117) implements three security checks:

1. Rejects absolute paths: `Path.type(path) == :absolute`
2. Rejects `..` traversal: `String.contains?(path, "..")`
3. Rejects resolved paths outside workflows dir: `String.starts_with?(resolved, Path.expand(workflows_dir))`

**Current test coverage in `workflow_worker_test.exs`**:
- Line 98: Tests missing file (`/nonexistent/path/workflow.md`) -- this is an absolute path, so it actually hits the `:path_not_allowed` error, but the assertion (`{:error, {:workflow_not_found, _}}`) would **fail** since the actual return is `{:error, :path_not_allowed}`. This is a latent test bug.
- No test for `../` traversal
- No test for path that resolves outside workflows dir

**Finding - Blocking**: The `resolve_path/1` function is a security-critical path traversal guard, but `workflow_worker_test.exs` has zero tests that specifically validate rejection of:
- Absolute paths (e.g., `"/etc/passwd"`)
- Directory traversal (e.g., `"../../etc/passwd"`)
- Paths that resolve outside the workflows directory

The existing test at line 98 (`"/nonexistent/path/workflow.md"`) is technically an absolute path test, but the assertion pattern `{:error, {:workflow_not_found, _}}` does not match the actual return value `{:error, :path_not_allowed}` -- meaning this test would fail if actually run with the current implementation.

---

## 4. YAML Injection Tests (Workflow.Create)

**Status**: No YAML injection tests exist.

**Analysis**: `workflow/create.ex` added `validate_no_newlines/2` (lines 167-175) which is called for the `"description"` and `"channel"` fields (lines 32-33). This prevents YAML injection via newline characters that could break out of the quoted YAML string values in the frontmatter template.

**Current test coverage in `workflow/create_test.exs`**:
- Tests name validation thoroughly (lines 161-211)
- Tests cron validation (lines 217-236)
- Tests conflict detection (lines 242-254)
- **No test for newlines in description or channel**

**Finding - Blocking**: `validate_no_newlines/2` is a security guard against YAML injection, and it has zero test coverage. Needed tests:
- Description containing `\n` returns error
- Description containing `\r` returns error
- Channel containing `\n` returns error
- Valid description/channel without newlines passes (already covered by happy path)

---

## 5. parse_attendees Empty List Edge Cases

**Status**: Partially covered.

**Analysis**: `parse_attendees/1` in both `calendar/create.ex` (lines 92-98) and `calendar/update.ex` (lines 81-87) now returns `nil` for empty results (empty string, all-empty after split). The `maybe_put/3` function then omits the `:attendees` key entirely.

**Test coverage**:

| Edge Case | create_test.exs | update_test.exs |
|-----------|-----------------|-----------------|
| `nil` (not provided) | Covered (line 165-171, optional fields) | Covered (sparse updates, only requested fields) |
| Empty string `""` | Covered (line 203-209) | **Not tested** |
| Comma-separated with empties `"a,,b,"` | Covered (line 195-201) | **Not tested** (only happy path `"alice, bob"`) |
| Whitespace-only `"  "` | **Not tested** | **Not tested** |
| Comma-only `","` | **Not tested** | **Not tested** |
| Whitespace + commas `" , , "` | **Not tested** | **Not tested** |

**Finding - Minor**: `create_test.exs` covers empty string and comma-with-empties. `update_test.exs` is missing the empty string test (only has the happy path attendee test at line 137-143).

**Finding - Future**: Neither test file covers whitespace-only (`"  "`), comma-only (`","`) or whitespace-comma (`" , , "`) inputs. The implementation handles these correctly (trim + reject empty = nil), but explicit edge case tests would document the contract.

---

## Summary

| # | Finding | Severity | Area |
|---|---------|----------|------|
| 1 | Calendar create/update/list missing "no integration" nil-check test | **Blocking** | Calendar nil-check regression |
| 2 | WorkflowWorker missing path traversal rejection tests (absolute, `..`, outside-dir) | **Blocking** | Path traversal security |
| 3 | Workflow.Create missing YAML injection tests (newlines in description/channel) | **Blocking** | YAML injection security |
| 4 | WorkflowWorker test line 98 asserts wrong error pattern for absolute path | **Blocking** | Latent test bug |
| 5 | No dedicated Email.Helpers unit tests (truncate_log, truncate boundaries) | **Minor** | Email helpers coverage |
| 6 | Calendar update_test.exs missing empty-string attendees test | **Minor** | parse_attendees edge case |
| 7 | parse_limit catchall clause untested with non-standard types | **Minor** | Email helpers edge case |
| 8 | Whitespace-only / comma-only attendee inputs not tested | **Future** | parse_attendees completeness |

**Risk Tier**: HIGH
**Signal**: RED
**Coverage**: Calendar nil-check 0/3 handlers tested; path traversal 0/3 rejection paths tested; YAML injection 0/2 fields tested
**Uncertainty Coverage**: 3 of 3 HIGH areas flagged (calendar nil-check, path traversal, YAML injection) -- all have gaps
**Findings**: 4 blocking issues -- security-critical code paths lack test coverage

---

**Coder Domain for Routing**: backend (all findings are in Elixir test files under `test/assistant/`)
