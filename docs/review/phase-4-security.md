# Phase 4 Security Review — Gmail, Calendar, Workflow Skills

> Reviewer: pact-security-engineer
> Date: 2026-02-18
> PR: #9
> Scope: All Phase 4 additions — OAuth/Goth, Gmail skills, Calendar skills, Workflow system, Registry wiring

---

## Attack Surface Map

### Entry Points (User-Controlled Input)

| Surface | Input Source | Files |
|---------|-------------|-------|
| Email send/draft | `flags["to"]`, `flags["subject"]`, `flags["body"]`, `flags["cc"]` | `lib/assistant/skills/email/send.ex`, `draft.ex` |
| Email list/search/read | `flags["query"]`, `flags["from"]`, `flags["to"]`, `flags["id"]`, `flags["label"]`, `flags["limit"]` | `list.ex`, `search.ex`, `read.ex` |
| Calendar create/update | `flags["title"]`, `flags["start"]`, `flags["end"]`, `flags["description"]`, `flags["location"]`, `flags["attendees"]` | `lib/assistant/skills/calendar/create.ex`, `update.ex` |
| Calendar list | `flags["date"]`, `flags["from"]`, `flags["to"]`, `flags["calendar"]` | `calendar/list.ex` |
| Workflow create | `flags["name"]`, `flags["description"]`, `flags["prompt"]`, `flags["cron"]`, `flags["channel"]` | `lib/assistant/skills/workflow/create.ex` |
| Workflow run/cancel | `flags["name"]` | `workflow/run.ex`, `cancel.ex` |
| WorkflowWorker | `workflow_path` (from Oban job args) | `lib/assistant/scheduler/workflow_worker.ex` |

### Trust Boundaries

1. **User -> LLM -> Skill handler**: User input is parsed by the LLM into skill flags. The LLM is a semi-trusted intermediary.
2. **Skill handler -> Google API client**: Skill handlers validate flags and pass to API wrappers.
3. **Workflow file -> WorkflowWorker -> LLM**: Workflow prompt body is read from disk and will be sent to an LLM. The prompt body is trusted (written by workflow.create from user input or manually).
4. **WorkflowWorker -> Google Chat**: Workflow results posted to a Chat space specified in the workflow frontmatter.

---

## Findings

### FINDING: MEDIUM -- Atom exhaustion via `String.to_atom` in workflow job name generation

**Location**: `lib/assistant/scheduler/quantum_loader.ex:158`, `lib/assistant/skills/workflow/cancel.ex:114`

**Issue**: `workflow_job_name/1` calls `String.to_atom("workflow_#{safe_name}")`. While the name is sanitized via regex (`[^a-zA-Z0-9_-]` replaced with `_`), each unique workflow name creates a new atom. Atoms are never garbage collected in the BEAM VM. If an attacker can create many workflows with unique names (via `workflow.create`), they can exhaust the atom table (default 1,048,576 atoms), crashing the entire VM.

**Attack vector**: An attacker with access to the assistant (e.g., via Google Chat) repeatedly invokes `workflow.create` with incrementally unique names (`attack-1`, `attack-2`, ..., `attack-1000000`). Each creates a unique atom. Even with the name validation regex requiring lowercase alphanumeric, this provides sufficient entropy for exhaustion.

**Severity context**: The `validate_name/1` check in `workflow/create.ex:74` requires `^[a-z][a-z0-9_-]*$` which is good, but does not limit the total number of workflows that can be created. The attack requires ~1M invocations, which is rate-limited by Oban uniqueness and LLM throughput, but the atoms accumulate permanently.

**Remediation**:
- Use `String.to_existing_atom/1` with a pre-registered set, or use a `Registry` with string keys instead of atom-based Quantum job names.
- Alternatively, cap the total number of workflow files (e.g., check `File.ls` count before creation).

**Rating**: Minor (requires high volume, mitigated by LLM throughput bottleneck)

---

### FINDING: MEDIUM -- WorkflowWorker `resolve_path/1` lacks path traversal protection

**Location**: `lib/assistant/scheduler/workflow_worker.ex:99-105`

**Issue**: The `resolve_path/1` function in WorkflowWorker resolves paths as either absolute or relative to `Application.app_dir(:assistant)`. Unlike the `resolve_path/1` in `sub_agent.ex:896-911` (which performs an explicit `String.starts_with?` check against the base directory), this version does **no traversal validation**. An absolute path is used as-is, and a relative path is joined to the app dir without checking that the result stays within the expected directory.

**Attack vector**: If an attacker can control the `workflow_path` arg in an Oban job (either by manipulating the workflow.run skill with a crafted name that resolves to an unexpected path, or by directly inserting a job into the Oban queue), they could read arbitrary files. The `workflow_path` is typically set via `Path.relative_to_cwd(path)` in `workflow/run.ex:59` and `quantum_loader.ex:131`, so normal flow produces safe relative paths. However, the `perform/1` function accepts any `workflow_path` from Oban args without validation.

**Severity context**: Exploitation requires either (a) direct database access to insert crafted Oban jobs, or (b) a bug in the workflow name handling that resolves to an unintended path. The `validate_name/1` regex in `workflow/create.ex` constrains names to `[a-z][a-z0-9_-]*`, making normal-flow exploitation very difficult. The risk is primarily from defense-in-depth failure.

**Remediation**: Add the same path traversal check used in `sub_agent.ex`:
```elixir
defp resolve_path(path) do
  base = resolve_workflows_dir()  # or a dedicated safe base dir
  resolved = Path.expand(path, base)
  if String.starts_with?(resolved, base <> "/") do
    resolved
  else
    {:error, :path_traversal_denied}
  end
end
```

**Rating**: Minor (normal flow is safe; defense-in-depth gap)

---

### FINDING: MEDIUM -- Workflow `channel` field written to YAML without validation

**Location**: `lib/assistant/skills/workflow/create.ex:135-137`

**Issue**: The `flags["channel"]` value is interpolated directly into a YAML frontmatter string without any validation: `~s(channel: "#{flags["channel"]}")`. This has two sub-issues:

1. **YAML injection**: If the channel value contains a YAML-breaking sequence like `")\ncron: "* * * * *"` or similar, it could inject additional frontmatter fields. The value is wrapped in double quotes, but YAML double-quoted strings allow escape sequences. A value containing `"` would break the YAML structure.

2. **No space name format validation**: The channel value is later passed to `Chat.send_message/2` which validates `spaces/[A-Za-z0-9_-]+`, but a malformed channel value is stored permanently in the workflow file and will cause repeated error logs on every scheduled execution.

**Attack vector**: An LLM-mediated user provides `--channel 'arbitrary"string\nbad: true'` which gets written into the YAML frontmatter. The Loader's YAML parser may interpret this differently than intended, potentially injecting additional frontmatter keys.

**Remediation**:
- Validate the `channel` field format against the same `spaces/[A-Za-z0-9_-]+` regex used in `chat.ex:35` before writing it to the file.
- Escape or sanitize the value before YAML interpolation, or use a proper YAML serializer instead of string interpolation.

**Rating**: Minor (Chat module rejects invalid space names at send time; stored file is malformed but not exploitable beyond nuisance)

---

### FINDING: MEDIUM -- Workflow `description` field written to YAML without escaping

**Location**: `lib/assistant/skills/workflow/create.ex:126`

**Issue**: Similar to the `channel` field, the `description` value is interpolated into YAML via `~s(description: "#{flags["description"]}")`. A description containing double quotes or YAML special characters could break the frontmatter structure or inject additional fields.

**Attack vector**: User provides `--description 'My workflow"\ncron: "* * * * *"'` which could inject a cron field into a workflow that was not intended to be scheduled.

**Remediation**: Use a proper YAML serializer (e.g., `YamlElixir` encode) or escape special characters in all frontmatter values.

**Rating**: Minor (requires intentional crafting; cron expressions are validated on load by QuantumLoader)

---

### FINDING: LOW -- Overly broad OAuth scopes for single-purpose service account

**Location**: `lib/assistant/integrations/google/auth.ex:86-92`

**Issue**: The Goth instance is configured with all scopes simultaneously:
- `chat.bot`
- `drive.readonly`
- `drive.file`
- `gmail.modify`
- `calendar`

Every API call made by any integration uses a token with all these scopes. The principle of least privilege suggests that each integration should request only the scopes it needs.

**Attack vector**: If the access token is leaked (e.g., through a log statement, error response, or memory dump), the attacker gains access to all five scopes rather than just the one relevant to the integration that leaked it.

**Severity context**: Goth refreshes tokens proactively and they have a short TTL (~1 hour). Token values are not currently logged (the `Auth.token/0` function logs failures but not token values). This is a defense-in-depth concern.

**Remediation**: Consider using separate Goth instances per integration domain, each with only the scopes it needs. Alternatively, document the trade-off explicitly (simplicity vs. blast radius).

**Rating**: Future (defense-in-depth improvement, not an active vulnerability)

---

### FINDING: LOW -- Impersonation email not validated

**Location**: `config/runtime.exs:75-77`, `lib/assistant/application.ex:110-112`

**Issue**: The `GOOGLE_IMPERSONATE_EMAIL` environment variable is passed directly into the Goth `sub` claim without any format validation. If misconfigured (e.g., set to a non-email string), Goth will fail at token fetch time with an opaque Google API error rather than a clear configuration error.

**Attack vector**: Not an exploitable vulnerability. This is a robustness concern -- a deployment misconfiguration would cause silent auth failures rather than a clear startup error.

**Remediation**: Add a basic email format check (e.g., `String.contains?(email, "@")`) at config time, or validate at Goth startup.

**Rating**: Future (configuration robustness, not a security vulnerability)

---

### FINDING: LOW -- Gmail `validate_headers/3` does not check `from` option

**Location**: `lib/assistant/integrations/google/gmail.ex:158-167`

**Issue**: The `validate_headers/3` function checks `to`, `subject`, and `cc` for newline injection, but does not check the `from` option. The `build_rfc2822/4` function interpolates `from` directly into the RFC 2822 header at line 147.

**Severity context**: **Currently not exploitable.** The `:from` option is never passed by any skill handler in Phase 4. It defaults to `"me"` (line 143). However, if a future skill or integration passes user-controlled data as the `:from` option, header injection would be possible.

**Remediation**: Add `from` to the `validate_headers` check, or remove the unused `:from` option from the public API if it's not intended to be caller-controlled.

**Rating**: Future (not currently exploitable; defense-in-depth)

---

### FINDING: LOW -- Email subject logged in structured metadata

**Location**: `lib/assistant/skills/email/send.ex:76-78`, `draft.ex:75-77`

**Issue**: The email subject is logged (truncated to 50 chars) in structured metadata: `subject: truncate_log(subject)`. While truncation mitigates full exposure, email subjects may contain PII or sensitive information that should not appear in application logs.

**Severity context**: The truncation to 50 characters limits exposure. The `Logger.info` level means this will appear in production logs by default. This is a data minimization concern.

**Remediation**: Remove subject from log metadata, or log only a hash/fingerprint for correlation purposes.

**Rating**: Future (data minimization best practice)

---

## Areas Reviewed With No Issues Found

### Auth & Access Control
- **Goth `sub` claim handling**: Correctly uses domain-wide delegation pattern. The `sub` claim is set from an environment variable, not from user input. The conditional logic in `goth_source_opts/1` (application.ex:105-113) properly switches between scopes-only and claims+sub modes.
- **Gmail API user_id**: Hardcoded to `"me"` for send/draft operations (gmail.ex:74, 100), meaning all operations act on the impersonated user's mailbox. No user-controlled user_id parameter.
- **GoogleChatAuth plug**: Confirmed wired into router (router.ex:13-14, 26-28). Phase 3 JWT verification is intact.

### Input Handling
- **Email header injection prevention**: Properly implemented at two layers -- skill handlers (`send.ex:56-63`, `draft.ex:56-63`) check for `\r` and `\n` in to/subject/cc fields, and the Gmail client (`gmail.ex:158-167`) performs the same check. Defense in depth.
- **Calendar datetime normalization**: `normalize_datetime/1` uses a strict regex `@datetime_short_regex ~r/^\d{4}-\d{2}-\d{2} \d{2}:\d{2}$/` and only appends `:00Z` to matching inputs. Non-matching inputs pass through to the Google API which performs its own validation.
- **Workflow name validation**: `validate_name/1` in `workflow/create.ex:74` enforces `^[a-z][a-z0-9_-]*$`, preventing path traversal, null bytes, and special characters in filenames.
- **Email search query building**: `search.ex:87-103` builds Gmail queries from structured flags using prefix keys (`from:`, `to:`, `after:`, `before:`). The free-text `query` flag is passed as-is to Gmail's search API, which is the intended behavior (Gmail query language is server-validated).
- **Limit capping**: All list/search skills cap limits to `@max_limit 50` via `parse_limit/1`.

### Data Exposure
- **Registry does not expose credentials**: `Integrations.Registry.default_integrations/0` returns module references (`Drive`, `Gmail`, `Calendar`), not configuration or credentials. Safe to inject into context.
- **Token values not logged**: `Auth.token/0` logs failure reasons but not token strings.
- **GOOGLE_IMPERSONATE_EMAIL not logged**: The email is only read from env and stored in application config. Not present in any `Logger` call in the changed files.

### Dependency Risk
- No new dependencies added in Phase 4 (Goth, GoogleApi libraries were added in Phase 3). The PR only adds new application code.

### Cryptographic Misuse
- No new crypto code. Token management delegated to Goth (well-maintained library). Cloak encryption (Phase 2) unchanged.

### Configuration
- **Conditional Goth startup**: `maybe_goth/0` properly returns `[]` when credentials are absent, allowing dev startup without Google credentials.
- **QuantumLoader startup ordering**: Correctly placed after both `Assistant.Scheduler` and Oban in the supervision tree (application.ex:40).

### Phase 3 Regression Check
- **SSRF protection**: `notification_channel.ex` SSRF patterns unchanged. Google Chat `@valid_space_name` regex intact.
- **Path traversal fix**: `sub_agent.ex:896-911` resolve_path with `String.starts_with?` check unchanged.
- **Cloak encryption**: Vault configuration in `runtime.exs:113-122` unchanged.
- **GoogleChatAuth JWT verification**: Plug wired into router, not bypassed by Phase 4 changes.

---

## SECURITY REVIEW SUMMARY

| Severity | Count | Items |
|----------|-------|-------|
| Critical | 0 | -- |
| High | 0 | -- |
| Medium | 4 | Atom exhaustion, WorkflowWorker path traversal gap, YAML injection in channel, YAML injection in description |
| Low | 3 | Broad OAuth scopes, unvalidated impersonation email, unvalidated `from` header option, subject in logs |

**Overall assessment: PASS WITH CONCERNS**

The Phase 4 code demonstrates good security awareness overall -- email header injection is properly prevented at two layers, input validation is present on key fields, the Registry safely exposes module references rather than credentials, and Phase 3 security fixes are not regressed.

The primary concerns are:
1. **Workflow YAML frontmatter construction** uses string interpolation instead of a proper serializer, creating injection risk in `channel` and `description` fields (medium)
2. **WorkflowWorker lacks path traversal protection** that was implemented in the sibling `sub_agent.ex` resolve_path (medium, defense-in-depth)
3. **Atom exhaustion** via unbounded workflow creation (medium, rate-limited by LLM throughput)

None of these are blocking for merge, but items 1 and 2 should be addressed before production deployment.
