# Security Review: PR #1 — Skills-First Assistant Foundation

**Reviewer**: Security Engineer
**Date**: 2026-02-18
**Scope**: Full Phase 1 PR — credential handling, user data isolation, input validation, LLM output safety, webhook endpoints, file access, atom exhaustion, prompt injection surface

---

## BLOCKING Findings

### B1. Sentinel stub always approves — no safety gate on sub-agent actions

**Files**: `lib/assistant/orchestrator/sentinel.ex:75-83`, `lib/assistant/orchestrator/sub_agent.ex:583`, `lib/assistant/memory/agent.ex:580`

The Sentinel security gate is a no-op stub that always returns `{:ok, :approved}`. Every sub-agent tool call passes through this check, and every call is auto-approved. This means a sub-agent instructed by LLM output can execute any skill in its scope with zero validation of whether the action aligns with the user's intent.

**Impact**: If any skill in Phase 2+ has side effects (email sending, file deletion, API calls), the LLM can invoke them without human-in-the-loop confirmation. The `@moduledoc` acknowledges this is Phase 2 work, but there is no mechanism to flag irreversible actions even at the logging level.

**Recommendation**: Before adding any side-effecting skills, implement at minimum a deny-list for irreversible action types (e.g., `delete`, `send`, `write_external`) that blocks by default until the real Sentinel is built. Add a `@sentinel_mode` compile-time config toggle (:stub | :active) so the risk is explicit.

**Severity**: Blocking for any Phase 2 work that adds side-effecting skills. Acceptable for Phase 1 if ONLY read-only memory skills exist.

---

### B2. Webhook endpoints accept unauthenticated POST requests

**Files**: `lib/assistant_web/router.ex:21-26`, `lib/assistant_web/controllers/webhook_controller.ex:6-18`

The `/webhooks/telegram` and `/webhooks/google-chat` endpoints accept any POST request with no authentication. Telegram webhooks should validate the `X-Telegram-Bot-Api-Secret-Token` header against the configured `TELEGRAM_WEBHOOK_SECRET`. Google Chat webhooks should validate the bearer token from the request.

Currently these are placeholder stubs that return `%{status: "ok"}`, so the immediate risk is limited. However, they are publicly routable endpoints.

**Impact**: An attacker can send arbitrary payloads to these endpoints. When real handlers are added, if authentication is forgotten, any internet user could inject messages into conversations.

**Recommendation**: Add authentication middleware (a Plug) for each webhook route BEFORE implementing real handlers. At minimum for the stubs, return 403 when no valid auth token is present. The `TELEGRAM_WEBHOOK_SECRET` is already configured in `runtime.exs:78-79` but never consumed by the controller.

**Severity**: Blocking for any Phase 2 webhook implementation. Low risk in current stub form but the architectural gap must be tracked.

---

## MINOR Findings

### M1. Context files path traversal — `resolve_path/1` allows arbitrary file reads

**File**: `lib/assistant/orchestrator/sub_agent.ex:864-870`

The `resolve_path/1` function accepts file paths from `dispatch_agent` parameters (ultimately from LLM tool call arguments) and resolves them relative to `File.cwd!()` or uses them as absolute paths. There is no validation against path traversal (e.g., `../../etc/passwd` or `/etc/shadow`).

```elixir
defp resolve_path(path) do
  if Path.type(path) == :absolute do
    path  # Any absolute path accepted
  else
    Path.join(File.cwd!(), path)  # ../../../ traversal possible
  end
end
```

The LLM orchestrator controls these paths (not direct user input), but LLM outputs are not trusted — prompt injection or hallucination could produce adversarial paths.

**Impact**: A sub-agent could read any file the BEAM process has access to. In production containers this is mitigated by the `nobody` user (Dockerfile:78) but could still leak env vars, config files, or `/proc/self/environ`.

**Recommendation**: Validate that resolved paths fall within an allowed base directory (e.g., project root). Reject absolute paths that escape the project tree:
```elixir
defp resolve_path(path) do
  base = File.cwd!()
  resolved = Path.expand(path, base)
  if String.starts_with?(resolved, base), do: resolved, else: {:error, :path_traversal}
end
```

---

### M2. `String.to_atom/1` from YAML — atom table exhaustion vector

**Files**: `lib/assistant/config/loader.ex:274,287,289,292`, `lib/assistant/config/prompt_loader.ex:194,233,282`

Both `Config.Loader` and `PromptLoader` call `String.to_atom/1` on strings from YAML files. The BEAM atom table is finite (~1M atoms, not garbage collected). While these are loaded from trusted config files at boot (not user input), the hot-reload path (`Config.Watcher` triggering `reload/0`) means repeated reloads with varying keys could accumulate atoms.

- `Config.Loader` atomizes defaults keys/values, model tiers, use_cases, and cost_tiers
- `PromptLoader` atomizes filenames and section names from YAML

**Impact**: Low in practice because config files are developer-controlled and the set of keys is bounded. However, if a malformed config.yaml is written during development with many unique keys, a reload loop could slowly exhaust the atom table.

**Recommendation**: Use `String.to_existing_atom/1` where possible (for known enums like tier, cost_tier). For truly dynamic keys, keep them as strings. This is a defense-in-depth measure, not an urgent fix.

---

### M3. No request body size limit on webhook endpoints

**File**: `lib/assistant_web/endpoint.ex:18-21`

The `Plug.Parsers` configuration has no `:length` option:

```elixir
plug Plug.Parsers,
  parsers: [:json],
  pass: ["application/json"],
  json_decoder: Phoenix.json_library()
```

The default body size limit is 8MB. For a webhooks-only API, this is generous. Telegram webhook payloads are typically under 10KB.

**Impact**: An attacker could send large payloads to webhook endpoints causing memory pressure on the BEAM. Not a full DoS vector due to Bandit/Cowboy limits, but unnecessarily permissive.

**Recommendation**: Set `length: 1_000_000` (1MB) or lower as appropriate for webhook payloads.

---

### M4. Dev/test secret_key_base committed to source

**Files**: `config/dev.exs:23`, `config/test.exs:19`

Both dev and test configs contain hardcoded `secret_key_base` values:
- dev: `"cE7iGbkPg82Z/NQJ3+qLJxMV8U40x0ykw7fhsotbBZXbf6HdctY/V0FNHuVZ3pSa"`
- test: `"27fsLlwxFAdrfzZvsTKefyNOFNT2ucWuIv/xYSS2myafQ6FEGytY1Gew0fD2BWU2"`

**Impact**: These are development-only values and the production `secret_key_base` is properly loaded from `SECRET_KEY_BASE` env var in `runtime.exs:33-38`. This is standard Phoenix convention. Mentioned for completeness.

**Recommendation**: No action needed. This is idiomatic Phoenix. Production key is properly env-sourced.

---

### M5. OpenRouter API response body logged on unexpected format

**File**: `lib/assistant/integrations/openrouter.ex:315`

```elixir
Logger.error("OpenRouter unexpected response format", body: inspect(body))
```

If an OpenRouter response contains unexpected data (error messages, rate limit details with account info), the full body is logged. In production with structured logging to external services, this could expose API account details.

**Impact**: Low. OpenRouter responses typically contain model output, not credentials. But if the API returns error messages with internal details, these end up in logs.

**Recommendation**: Truncate the logged body to a reasonable size (e.g., first 500 characters) or log only the top-level keys.

---

### M6. `PromptLoader` uses `Code.eval_quoted/2` — EEx template injection risk

**File**: `lib/assistant/config/prompt_loader.ex:273`

```elixir
{result, _binding} = Code.eval_quoted(compiled_template, assigns: binding)
```

EEx templates are compiled and evaluated at runtime. If an attacker could modify files in `config/prompts/`, they could inject arbitrary Elixir code executed via `Code.eval_quoted`. The templates are loaded from the local filesystem, not from user input.

**Impact**: This is standard EEx usage and the risk is limited to filesystem-level compromise. The templates are developer-authored YAML files. Hot-reload via `Config.Watcher` means any filesystem write to `config/prompts/` triggers re-evaluation.

**Recommendation**: No immediate action for Phase 1. For Phase 2, if prompt templates become user-configurable (e.g., per-organization custom prompts), switch to a sandboxed template engine that prevents code execution.

---

### M7. `memory_entries.user_id` allows NULL — cross-user data access risk

**Files**: `priv/repo/migrations/20260218120000_create_core_tables.exs:96`, `lib/assistant/schemas/memory_entry.ex:48`

The `memory_entries.user_id` column allows NULL (`on_delete: :nilify_all`). The Ecto schema lists `user_id` in `@optional_fields`, not `@required_fields`. This means memory entries can exist without a user association.

**Impact**: Queries that filter by `user_id` will correctly scope results, but entries with `NULL` user_id are orphaned and could be returned by queries that don't filter on user_id. If a future query uses `where: is_nil(user_id)` or a broad scan without user scoping, it could surface memories belonging to no user (or previously belonging to a deleted user).

**Recommendation**: Either make `user_id` NOT NULL on memory_entries (matching memory_entities which requires it), or ensure ALL memory query functions include `WHERE user_id = ?` scoping. The asymmetry between memory_entities (user_id required) and memory_entries (user_id optional) is a design inconsistency worth addressing.

---

## FUTURE Considerations

### F1. No rate limiting on webhook endpoints

The application has circuit breakers and rate limiters internally (`lib/assistant/resilience/rate_limiter.ex`), but no external rate limiting on the HTTP endpoints. For Phase 2 when webhooks are live, add Plug-based rate limiting (e.g., `PlugAttack` or `Hammer`) per-IP or per-source.

### F2. LLM response content used in system operations without sanitization

Throughout the codebase, LLM responses (tool call arguments, content) are trusted and passed directly into system operations:
- Tool names from LLM responses are matched as strings (`sub_agent.ex:555-565`)
- Skill arguments from LLM are passed directly to skill handlers (`sub_agent.ex:569`)
- Agent IDs from LLM are used as process registry keys (`dispatch_agent.ex:211`)

This is acceptable in Phase 1 where the LLM is the only caller and skills are read-only. For Phase 2 with write skills, consider:
- Validating all LLM-provided parameters against schemas before execution
- Treating LLM output as untrusted user input at the skill execution boundary

### F3. Conversation messages stored in GenServer state — memory pressure

**File**: `lib/assistant/orchestrator/engine.ex:133`

The full conversation history is held in GenServer memory (`state.messages`). Long conversations could cause memory pressure. The context trimming in `Context.build` controls what's sent to the LLM, but the full history stays in the process.

For Phase 2, consider persisting messages to the database and loading on-demand, or implementing a max-messages cap in the GenServer state.

### F4. PII in memory entries and conversation content

Memory entries store conversation content verbatim. The `CLOAK_ENCRYPTION_KEY` config in `runtime.exs:93-102` suggests field-level encryption was planned (via Cloak.Ecto) but no schemas use encrypted fields yet. For Phase 2, encrypt `memory_entries.content` and `messages.content` at rest.

### F5. `show_sensitive_data_on_connection_error: true` in dev

**File**: `config/dev.exs:14`

This is standard Phoenix dev config and only active in dev environment. Mentioned for awareness — ensure this never leaks to production (it won't, since dev.exs is not loaded in prod).

### F6. No CORS configuration

**File**: `lib/assistant_web/endpoint.ex`

No CORS headers are configured. This is correct for a webhook-only backend with no browser clients. If a future Phase adds a web dashboard, CORS will need configuration.

---

## Positive Security Observations

1. **API key handling**: All secrets are properly loaded from environment variables in `runtime.exs`. No hardcoded API keys in source. `env.example` contains only placeholder values.

2. **`.gitignore` coverage**: `.env` and `.env.*` are properly ignored. No risk of committing secrets.

3. **User-scoped entities**: The `memory_entities` migration properly adds `user_id` FK with a unique constraint on `[:user_id, :name, :entity_type]`, preventing cross-user entity confusion.

4. **Skill scope enforcement**: Sub-agents can only use skills explicitly granted by the orchestrator. Both the tool definition (enum restriction) and runtime check (`if skill_name in dispatch_params.skills`) enforce this.

5. **Circuit breakers and limits**: Multi-level limit enforcement (per-turn agent count, per-agent tool budget, per-skill circuit breakers) provides defense-in-depth against runaway LLM loops.

6. **Docker security**: Production container runs as `nobody` user, minimizing privilege. Multi-stage build keeps build tools out of production image.

7. **Production SSL**: `force_ssl` with HSTS is enabled in `config/prod.exs:11`.

8. **Binary IDs**: All primary keys use UUIDs (`binary_id`), preventing enumeration attacks.

9. **Database constraints**: Extensive use of CHECK constraints, unique indexes, and foreign keys at the database level (not just application level).

---

## Summary

| Severity | Count | Status |
|----------|-------|--------|
| Blocking | 2 | Must address before side-effecting skills (Phase 2) |
| Minor | 7 | Should address in this PR or early Phase 2 |
| Future | 6 | Track for Phase 2 planning |

The Phase 1 foundation is security-conscious in its credential handling, user scoping, and limit enforcement. The two blocking findings (Sentinel stub and unauthenticated webhooks) are acknowledged architectural gaps with clear Phase 2 intent, but they must be gated before any write skills or real webhook handlers are deployed. The most actionable minor finding is M1 (path traversal in context_files) which should be fixed in this PR.
