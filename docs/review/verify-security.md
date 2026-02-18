# Security Verification: M1 Path Traversal Fix

**Reviewer**: Security Engineer
**Date**: 2026-02-18
**Commit**: 268273f
**Scope**: M1 finding from `docs/review/security-engineer-review.md`

---

## Resolved

### Checklist

1. **Does it call `Path.expand/1` to resolve `../` sequences?**
   Yes. `sub_agent.ex:882-885` — both absolute and relative paths are expanded via `Path.expand/1` (absolute) or `Path.expand/2` (relative, anchored to `File.cwd!()`). This canonicalizes symlinks and `../` sequences before the boundary check.

2. **Does it validate the result stays within the allowed base?**
   Yes. `sub_agent.ex:888` — `String.starts_with?(resolved, base <> "/")` ensures the resolved path is a child of the project root. The `or resolved == base` clause handles the edge case of the base directory itself. The trailing `/` in `base <> "/"` prevents prefix-matching attacks (e.g., `/app` matching `/app-secret`).

3. **Does `load_context_files/2` handle `{:error, :path_traversal_denied}` gracefully?**
   Yes. `sub_agent.ex:814-820` — the error branch logs a warning with the original path and agent_id, then returns `acc` (skips the file). This matches the existing pattern for unreadable files. No crash, no data leak.

### Attack vectors verified as blocked

| Vector | Blocked? |
|--------|----------|
| `../../etc/passwd` (relative traversal) | Yes — expands to `/etc/passwd`, fails `starts_with?` check |
| `/etc/shadow` (absolute path) | Yes — expands to `/etc/shadow`, fails `starts_with?` check |
| `../../../proc/self/environ` | Yes — expands outside base, rejected |
| `./valid/file.txt` (legitimate relative) | Yes — resolves within base, accepted |
| Symlink to outside directory | Yes — `Path.expand/1` resolves symlinks |
