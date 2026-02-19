# Project Memory

This file contains project-specific memory managed by the PACT framework.
The global PACT Orchestrator is loaded from `~/.claude/CLAUDE.md`.

## Retrieved Context
<!-- Auto-managed by pact-memory skill. Last 3 retrieved memories shown. -->

## Working Memory
<!-- Auto-managed by pact-memory skill. Last 3 memories shown. Full history searchable via pact-memory skill. -->

## Pinned Architecture

### Shared Helpers Pattern (Phase 4)
All helper extraction follows this hierarchy — do NOT re-duplicate functions:
- `Skills.Helpers` — cross-domain: `parse_limit/3` (value, default, max)
- `Email.Helpers` — email-domain: `has_newlines?`, `truncate_log`, `truncate`, `full_mode?`, `parse_limit/1` (delegates to Skills.Helpers)
- `Calendar.Helpers` — calendar-domain: `normalize_datetime`, `parse_attendees`, `maybe_put`, `parse_limit/1` (delegates to Skills.Helpers)
- `Workflow.Helpers` — workflow-domain: `resolve_workflows_dir/0`
- All helper modules use `@moduledoc false`

### Integration Injection Pattern
**Always use nil-check pattern** — never fall back to real module:
```elixir
case Map.get(context.integrations, :gmail) do
  nil -> {:ok, %Result{status: :error, content: "Gmail integration not configured."}}
  gmail -> ...
end
```
This applies to `:gmail`, `:calendar`, `:drive`. The fallback-to-real-module pattern was removed in Phase 4.

### Workflow File Security
All workflow skills that take a `name` flag must validate with `~r/^[a-z][a-z0-9_-]*$/` before path construction. `WorkflowWorker.resolve_path/1` rejects absolute paths, `../` traversal, and symlinks as a safety net — but callers must also validate.

### YAML Frontmatter Safety
`workflow/create.ex` validates user-controlled fields with `validate_field/2`: rejects embedded newlines (`\n`, `\r`) and double-quotes (`"`). Apply same pattern to any new skill that writes YAML files.

### Phase Status
- Phase 1-4 complete and merged (PR #9). Branch: `main`.
- Phase 4 covers: Gmail (5 skills), Calendar (3 skills), Workflow scheduler (4 skills + WorkflowWorker + QuantumLoader).
