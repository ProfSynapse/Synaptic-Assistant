# Security Review: Phase 4 Minor Fixes (PR #9)

**Reviewer**: pact-security-engineer
**Date**: 2026-02-19
**Commit**: 6938d5a
**Scope**: Path traversal fix (workflow_worker.ex), YAML injection prevention (workflow/create.ex), and surrounding input handling

---

## 1. Path Traversal Fix (`resolve_path/1` in workflow_worker.ex)

### What was fixed

`resolve_path/1` (lines 104-117) now implements a two-layer defense:
1. **Pre-check**: Rejects paths that are absolute (`Path.type(path) == :absolute`) or contain `..` segments (`String.contains?(path, "..")`)
2. **Post-expand check**: After `Path.join` + `Path.expand`, verifies the resolved path starts with the expanded workflows directory

### Assessment: Correct and robust

**Attack vectors tested:**

| Vector | Blocked? | Mechanism |
|--------|----------|-----------|
| Absolute path: `/etc/passwd` | Yes | Pre-check: `Path.type(path) == :absolute` |
| Parent traversal: `../../etc/passwd` | Yes | Pre-check: `String.contains?(path, "..")` |
| URL-encoded: `..%2F..%2Fetc%2Fpasswd` | Yes | Elixir does not URL-decode file paths; the literal `%2F` is not a `/` to the filesystem. `String.contains?` would also catch the `..` prefix. |
| Null byte: `foo.md\0.txt` | Yes | BEAM/Erlang file operations reject null bytes by default (raises `ArgumentError`). Even without that, the `starts_with?` post-expand check provides a safety net. |
| Symlink escape: `priv/workflows/link -> /etc/` | Partially | `Path.expand/1` resolves `..` and relative components but does NOT follow symlinks. A symlink inside `priv/workflows/` pointing outside would pass both checks because `Path.expand` returns the logical path, not the physical one. However, the attacker would need write access to the filesystem to plant such a symlink. |
| Double-dot in filename: `file..name.md` | Yes (false positive possible) | `String.contains?(path, "..")` would reject `file..name.md`. This is a minor functional annoyance but errs on the safe side. |

**Post-expand `starts_with?` check** (line 111) is the real defense-in-depth layer. Even if the pre-check missed something, the expanded path is verified against the expanded workflows directory. This is the correct pattern.

**One subtlety**: `Path.expand/1` on line 109 expands relative to `cwd`, and `Path.expand(workflows_dir)` on line 111 does the same. As long as both expansions use the same base (which they do, since neither takes a second argument), the comparison is consistent.

### Findings

```
FINDING: MINOR -- Symlink escape not covered by Path.expand
Location: lib/assistant/scheduler/workflow_worker.ex:109-111
Issue: Path.expand resolves ".." and relative components but does not resolve
       symlinks. A symlink inside priv/workflows/ pointing outside the directory
       would pass the starts_with? check.
Attack vector: Requires filesystem write access to plant a symlink inside
       priv/workflows/. Not exploitable via the application's own APIs since
       workflow.create uses validate_name (^[a-z][a-z0-9_-]*$) which prevents
       writing arbitrary filenames, and File.write! creates regular files, not symlinks.
Remediation: For hardening, use File.read_link/1 before File.read to detect
       symlinks, or use :file.read_file_info (follow_links: false) to verify the
       target is a regular file. Not urgent given the attacker model.
```

```
FINDING: MINOR -- False positive rejection of ".." in filenames
Location: lib/assistant/scheduler/workflow_worker.ex:105
Issue: String.contains?(path, "..") rejects any path containing two consecutive
       dots, including legitimate filenames like "v2..0-migration.md". The post-expand
       starts_with? check would catch actual traversal, so the pre-check is defense-
       in-depth that is slightly over-broad.
Attack vector: None (functional issue, not security).
Remediation: Could narrow to checking for path separator adjacency
       (e.g., String.contains?(path, ["../", "..\\"])) but current behavior is
       safe-side and acceptable.
```

---

## 2. YAML Injection Prevention (`validate_no_newlines/2` in workflow/create.ex)

### What was fixed

`validate_no_newlines/2` (lines 167-175) rejects values containing `\n` or `\r`. Applied to `description` (line 32) and `channel` (line 33).

### Assessment: Correct for the target fields; one gap identified

**Field-by-field analysis of `build_content/1` (lines 105-137):**

| Field | In YAML? | Validation | Safe? |
|-------|----------|------------|-------|
| `name` | Yes: `name: "#{name}"` | `validate_name`: `^[a-z][a-z0-9_-]*$` | Yes -- regex prevents all injection characters |
| `description` | Yes: `description: "#{desc}"` | `validate_no_newlines` | Partially -- see finding below |
| `cron` | Yes: `cron: "#{cron}"` | `Crontab.CronExpression.Parser.parse` | Yes -- parser rejects anything that isn't a valid cron expression; cron tokens are strictly `[0-9*,/-]` |
| `channel` | Yes: `channel: "#{channel}"` | `validate_no_newlines` | Partially -- see finding below |
| `prompt` | No: after `---` fence | None needed for YAML injection | See finding below |

**Newline check coverage**: `validate_no_newlines` checks for `\n` and `\r`. This covers LF, CR, and CRLF. Adequate for YAML injection prevention since YAML multi-line requires actual newline characters.

### Findings

```
FINDING: MINOR -- YAML quote breakout in description and channel
Location: lib/assistant/skills/workflow/create.ex:108,118
Issue: description and channel values are interpolated inside double-quoted YAML
       strings: description: "#{flags["description"]}". If the value contains a
       literal double-quote character ("), the YAML structure breaks:
         description: "value with "quotes""
       This produces invalid YAML, causing parse failures when the workflow is
       later loaded by WorkflowWorker/QuantumLoader. While this is a denial-of-
       service (corrupted workflow file) rather than an injection (the YAML parser
       would reject it, not execute attacker-controlled keys), it degrades
       availability.
Attack vector: User provides description containing double quotes. The resulting
       file has invalid YAML. When QuantumLoader or WorkflowWorker reads it,
       parse_frontmatter returns {:error, ...} and the workflow silently fails.
Remediation: Escape double quotes in interpolated values, e.g.:
       String.replace(value, "\"", "\\\"") before interpolation. Or use a proper
       YAML serializer (Jason.encode! produces valid JSON which is valid YAML for
       scalar strings).
```

```
FINDING: MINOR -- Prompt body can inject a premature frontmatter close
Location: lib/assistant/skills/workflow/create.ex:135
Issue: The prompt field is written after the closing --- fence:
         ---
         #{frontmatter}
         ---
         #{String.trim(flags["prompt"])}
       If the prompt starts with "---\n", the written file will contain a second
       frontmatter block. When parsed by Loader.parse_frontmatter/1, the regex
       String.split(content, ~r/^---\s*$/m, parts: 3) splits on the FIRST two
       --- delimiters, so the user-injected --- in the body would become part of
       the body string, not a new frontmatter block.

       However, if the prompt contains EXACTLY "---" on its own line after other
       content, and the parsing logic encounters it, the behavior depends on the
       parts: 3 limit. With parts: 3, only the first two --- lines are used as
       delimiters. The rest is body. This is safe by design.
Attack vector: Not exploitable -- parse_frontmatter's parts: 3 limit prevents
       the prompt body from injecting new frontmatter keys.
Remediation: No action needed. The existing parser design handles this correctly.
       Document the parts: 3 invariant as a security-relevant design decision.
```

---

## 3. Email Header Injection (`has_newlines?` in email/helpers.ex)

### Assessment: Correct and properly layered

Defense-in-depth with TWO layers:

1. **Skill layer** (send.ex:57-63, draft.ex:57-63): Validates `to`, `subject`, `cc` fields via `Helpers.has_newlines?` before calling the Gmail client
2. **Integration layer** (gmail.ex:158-166): `validate_headers/3` independently checks the same fields for `\r` and `\n`

Both layers check for `\r` and `\n` independently. The integration layer provides a safety net if any skill handler is added in the future that forgets the check.

The `body` field is intentionally not checked for newlines (email bodies legitimately contain newlines) and is placed after the RFC 2822 header/body separator (`\r\n\r\n`), so it cannot inject headers.

**No findings for email.**

---

## 4. Path Construction in workflow.run, workflow.cancel, workflow.create

### Assessment: Safe due to `validate_name` constraints

`workflow.run`, `workflow.cancel`, and `workflow.create` all build file paths via:
```elixir
Path.join(Helpers.resolve_workflows_dir(), "#{name}.md")
```

The `name` value comes from user flags. In `workflow.create`, it passes through `validate_name/1` which enforces `^[a-z][a-z0-9_-]*$`. This regex prevents:
- Path separators (`/`, `\`)
- Parent directory traversal (`..`)
- Null bytes
- Any special characters

**However**, `workflow.run` and `workflow.cancel` do NOT call `validate_name`. They accept any `flags["name"]` string and pass it directly to `workflow_path/1`:

```elixir
# run.ex:37
path = workflow_path(name)
```

### Findings

```
FINDING: MINOR -- workflow.run and workflow.cancel lack name validation
Location: lib/assistant/skills/workflow/run.ex:37, lib/assistant/skills/workflow/cancel.ex:36
Issue: Both skills construct a file path from flags["name"] without validating
       the name format. A name like "../../etc/passwd" would produce:
         Path.join(workflows_dir, "../../etc/passwd.md")
       The File.exists? check on the next line would then test a path outside
       the workflows directory.

       For workflow.run, the path is passed to Path.relative_to_cwd and then to
       Oban as workflow_path, which is later consumed by WorkflowWorker.perform.
       WorkflowWorker's resolve_path/1 DOES have the traversal check, so the
       actual file read is protected.

       For workflow.cancel, File.exists? is followed by either
       QuantumLoader.cancel(name) (which only removes a Quantum job by name lookup
       in a map -- safe) or File.rm(path) if --delete is set.

       File.rm with a traversed path could delete arbitrary .md files if the
       traversal lands on a valid path. Example:
         name = "../../some-other-dir/target"
         path = Path.join(workflows_dir, "../../some-other-dir/target.md")
       If that file exists, cancel with --delete would remove it.

       Practical risk is LOW because:
       (a) The attacker must know a valid relative path from the workflows dir
       (b) The path gets ".md" appended, limiting targets
       (c) File.rm only deletes files, not directories
       (d) This is an assistant tool invoked by the user/agent, not an external API
Attack vector: User invokes workflow.cancel --name "../../config/some-config"
       --delete. If a .md file exists at that relative path from the workflows
       directory, it would be deleted.
Remediation: Add validate_name (or at minimum a path traversal check) to
       workflow.run and workflow.cancel before constructing the path. Reuse the
       regex from workflow.create or the resolve_path pattern from workflow_worker.
```

---

## 5. YAML Injection in workflow.build (`build.ex`)

### Findings

```
FINDING: MINOR -- Unquoted and unvalidated YAML interpolation in workflow.build
Location: lib/assistant/skills/workflow/build.ex:97-103
Issue: generate_workflow_file/2 writes:
         name: #{full_name}
         description: #{flags["description"]}#{schedule_line}

       Unlike workflow.create which wraps values in double quotes, workflow.build
       writes name and description WITHOUT YAML quotes. The name is validated via
       validate_name (^[a-z][a-z0-9_]*$) so it's safe. But the description field
       has no newline or special character validation.

       A description containing a newline could inject arbitrary YAML keys:
         description = "legit\nhandler: Elixir.Malicious.Module"

       Would produce:
         description: legit
         handler: Elixir.Malicious.Module

       The handler field is used by Loader.build_skill_definition to resolve a
       module via String.to_existing_atom. While to_existing_atom limits the
       attack to already-loaded modules, an attacker could redirect the skill
       handler to any loaded module that has an execute/2 function.

       Additionally, the schedule field (line 97):
         schedule: "#{flags["schedule"]}"
       is double-quoted but has no validation for quotes or newlines.
Attack vector: User provides a description with embedded newlines to inject
       YAML frontmatter keys (name, handler, schedule, tags) into the generated
       skill file.
Remediation: Add validate_no_newlines for description and schedule fields in
       workflow.build, and either quote the YAML values or use a proper YAML
       serializer.
```

---

## 6. Google Chat `space_name` Validation

### Assessment: Correct

`chat.ex:55` validates `space_name` against `~r/^spaces\/[A-Za-z0-9_-]+$/` before constructing the URL. This prevents:
- Path traversal in the URL
- Injection of query parameters
- SSRF via arbitrary URL construction

The regex is strict and correct.

---

## Summary

### Findings Table

| # | Severity | Title | File | Blocking? |
|---|----------|-------|------|-----------|
| 1 | Minor | Symlink escape not covered by Path.expand | workflow_worker.ex:109 | No |
| 2 | Minor | False positive ".." rejection in filenames | workflow_worker.ex:105 | No |
| 3 | Minor | YAML quote breakout in description/channel | workflow/create.ex:108 | No |
| 4 | Minor | Prompt body frontmatter injection (NOT exploitable) | workflow/create.ex:135 | No |
| 5 | Minor | workflow.run and workflow.cancel lack name validation | run.ex:37, cancel.ex:36 | No |
| 6 | Minor | Unquoted YAML interpolation in workflow.build | workflow/build.ex:97-103 | No |

### Areas With No Issues Found

- **Auth & access control**: Not applicable to reviewed changes (no auth logic modified)
- **Email header injection**: Correct two-layer defense in send.ex, draft.ex, and gmail.ex
- **Google Chat space_name**: Correct regex validation
- **Cryptographic misuse**: No crypto code in scope
- **Dependency risk**: No dependency changes in scope
- **Configuration**: No configuration security concerns found

### SECURITY REVIEW SUMMARY

```
Critical: 0
High:     0
Medium:   0
Minor:    6
Overall assessment: PASS WITH CONCERNS
```

**Rationale**: The two targeted fixes (path traversal in workflow_worker.ex, YAML injection in create.ex) are correctly implemented and effective. The path traversal fix uses proper defense-in-depth with both pre-check and post-expand verification. The YAML injection fix correctly blocks newlines in the critical fields.

The minor findings are defense-in-depth gaps and consistency issues rather than active vulnerabilities. The most actionable are #5 (adding name validation to run.ex and cancel.ex for consistency with create.ex) and #6 (adding input validation to workflow.build). Neither is blocking because the attack surface requires the user/agent themselves to provide malicious input, and the downstream systems (WorkflowWorker's resolve_path, Loader's parse_frontmatter) provide additional safety layers.

**Recommended follow-up (non-blocking)**:
1. Add `validate_name` or equivalent path check to `workflow.run` and `workflow.cancel` for consistency
2. Add newline/quote validation to `workflow.build`'s description and schedule fields
3. Consider using a YAML serializer library instead of string interpolation for all frontmatter generation
