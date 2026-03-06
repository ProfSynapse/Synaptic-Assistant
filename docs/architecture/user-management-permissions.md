# Architecture: User Management, Permissions Enforcement, and Spending Limits

> Validated against codebase on 2026-03-06. Reference plan: `docs/plans/user-management-permissions-spending-plan.md`

---

## Validation Report

### 1. AccessScopes.Enforcer Placement — CONFIRMED

**Plan says**: Add scope check in SubAgent alongside SkillPermissions.

**Validated**: `sub_agent.ex:880-969` — `execute_use_skill/6` has a clear `cond` chain:
1. `is_nil(skill_name)` → error
2. `not SkillPermissions.enabled_for_user?(dispatch_params.user_id, skill_name)` → blocked (**insert scope check here, before this line**)
3. `skill_name not in dispatch_params.skills` → out of scope
4. `true` → sentinel check → approval gate → execute

**Add scope enforcement at line ~893**, as a new `cond` clause BEFORE the `SkillPermissions` check:

```elixir
not AccessScopes.Enforcer.skill_allowed?(dispatch_params.user_id, skill_name) ->
  {tc, "This feature is not available with your current access level."}
```

**Scope-to-domain mapping**: The plan proposes a mapping parallel to `@skill_prefix_to_group` in `skill_permissions.ex:27-32`. This works. The existing prefix-splitting pattern at `skill_permissions.ex:162-164` (`String.split(skill_name, ".", parts: 2)` → `[prefix, _action]`) should be reused.

**Mapping reference** (skill domains from `priv/skills/`):

| Skill Domain (prefix) | Access Scope |
|------------------------|--------------|
| `email`, `calendar`, `files` | `integrations` |
| `hubspot` | `integrations` |
| `workflow` | `workflows` |
| `memory` | `memory` |
| `web`, `images` | `chat` |
| `agents`, `tasks` | `chat` |

Unmapped prefixes → default-deny (log + reject).

**User ID bridging**: `dispatch_params.user_id` is the chat `user_id` (from `users` table). The Enforcer must bridge to `settings_user.access_scopes` via `Accounts.get_settings_user_by_user_id/1` (`accounts.ex:285-291`). Cache this lookup per-request since it's called once per skill execution.

### 2. SpendingLimits Enforcement Point — CONFIRMED

**Plan says**: Enforce in `LLMRouter.chat_completion/3` as single point.

**Validated**: `llm_router.ex:82-94` — `chat_completion/3` is a clean 12-line function that routes then delegates. ALL LLM callers in the app go through it:

| Caller | Location |
|--------|----------|
| Orchestrator loop | `loop_runner.ex:88` |
| Sub-agent loop | `sub_agent.ex:610` |
| Sub-agent queries | `sub_agent_query.ex:52` |
| Sentinel | `sentinel.ex:160` (via `@llm_router` behaviour) |
| Memory agent | `memory/agent.ex:416` |
| Turn classifier | `memory/turn_classifier.ex:149` |
| Compaction | `memory/compaction.ex:279` |

**Design**: Insert pre-flight check at the top of `chat_completion/3`:

```elixir
def chat_completion(messages, opts, user_id) when is_list(opts) do
  case SpendingLimits.Enforcer.check_budget(user_id) do
    :ok -> :proceed
    {:warning, pct} -> Logger.info("User #{user_id} at #{pct}% of budget")
    {:error, :over_budget} -> return {:error, :over_budget}
  end
  # ... existing routing logic
end
```

**IMPORTANT**: The `user_id` param here is the chat `user_id`. The spending enforcer needs to bridge to `settings_user_id` (the actual FK for the spending tables). Use `Accounts.get_settings_user_by_user_id/1`.

**Sentinel exemption**: Consider whether sentinel calls (security checks) should bypass spending limits. Blocking sentinel = security gap. Recommendation: YES, exempt sentinel. The `@llm_router` behaviour in `sentinel.ex:53` makes this possible — sentinel already uses a compile-time config for the router module. In tests it uses a mock; in prod it uses LLMRouter. Options:
- Add an `:exempt_spending_check` opt that sentinel passes
- Or check `Keyword.get(opts, :skip_spending_check, false)` in `chat_completion/3`

### 3. Upfront User Creation — CONFIRMED

**Plan says**: Create settings_user with nil `hashed_password` in same transaction as allowlist entry.

**Validated**: `accounts.ex:165-195` — `upsert_settings_user_allowlist_entry/3` already:
1. Takes `opts: [transaction?: true]` (wraps in `Repo.transact/1`)
2. Inserts/updates the allowlist entry
3. Calls `sync_matching_settings_user_access/1` which syncs `is_admin` and `access_scopes` to matching settings_user

**Adjustment needed**: Currently if no settings_user exists for the email, `sync_matching_settings_user_access/1` (`accounts.ex:714-725`) just returns `:ok`. The new `create_settings_user_from_admin/2` function should:
1. Call `upsert_settings_user_allowlist_entry` (with `transaction?: false`)
2. Then `Repo.insert` a new `SettingsUser` with `hashed_password: nil`, `email`, `full_name`, `access_scopes` from the entry
3. Wrap both in a single `Repo.transact`
4. Optionally auto-send invite via `deliver_login_instructions`

**Magic link with nil password**: CONFIRMED safe. `deliver_login_instructions` (`accounts.ex:612-625`) generates a token via `SettingsUserToken.build_email_token/2` — no password dependency anywhere in the path.

### 4. on_mount Scope Enforcement — CONFIRMED

**Plan says**: Add `require_scope` hook.

**Validated**: `settings_user_auth.ex:217-259` has three existing `on_mount` handlers:
- `:mount_current_scope` (line 217) — assigns `current_scope`
- `:require_authenticated` (line 221) — redirects if not logged in or disabled
- `:require_sudo_mode` (line 246) — re-auth check

**Pattern for `require_scope`**: Add a new `on_mount` clause that takes a scope name:

```elixir
def on_mount({:require_scope, scope_name}, _params, session, socket) do
  socket = mount_current_scope(socket, session)
  scope = socket.assigns.current_scope

  cond do
    is_nil(scope) or is_nil(scope.settings_user) ->
      {:halt, redirect_to_login(socket)}

    scope.admin? ->
      {:cont, socket}  # admins bypass scope checks

    scope_name in scope.privileges ->
      {:cont, socket}

    true ->
      {:halt, socket |> put_flash(:error, "Access denied.") |> redirect(to: ~p"/")}
  end
end
```

**Router wiring**: Use in `live_session` blocks:

```elixir
live_session :workflows,
  on_mount: [{SettingsUserAuth, {:require_scope, "workflows"}}] do
  # workflow routes
end
```

**Scope struct**: `scope.ex:21` — `defstruct settings_user: nil, admin?: false, privileges: []`. The `privileges` field is already populated from `settings_user.access_scopes` at `scope.ex:28-43`. Admins automatically get `"admin"` prepended.

### 5. Spending Schema FK — ADJUSTED

**Plan says**: Use `settings_user_id` FK based on connector_states pattern.

**Actual connector_states pattern**: `settings_user_connector_states` uses `user_id` referencing the `users` table (chat users), NOT `settings_users`. See migration `20260305110000`:
```elixir
add :user_id, references(:users, type: :binary_id, on_delete: :delete_all)
```

And the schema (`settings_user_connector_state.ex:28`):
```elixir
belongs_to :user, Assistant.Schemas.User
```

**However**, spending limits are admin-managed per settings_user (web dashboard user), not per chat user. A settings_user may not have a linked chat user (`user_id` is nullable on `settings_users`). The spending UI is in the admin panel where we have `settings_user.id`.

**Decision**: Use `settings_user_id` referencing `settings_users` table. This differs from the connector_states pattern but is correct for this use case:
- Spending limits are configured by admins in the web dashboard (settings_user context)
- Budget display is on the user detail page (settings_user context)
- Chat engine enforcement bridges via `Accounts.get_settings_user_by_user_id/1`

```elixir
# spending_limits migration
add :settings_user_id, references(:settings_users, type: :binary_id, on_delete: :delete_all)

# usage_records migration
add :settings_user_id, references(:settings_users, type: :binary_id, on_delete: :delete_all)
```

### 6. Scope-to-Skill Domain Mapping — CONFIRMED with refinement

**Plan says**: Add "workflows", "memory", "analytics" to the mapping.

**Validated skill domains** (from `priv/skills/` directory):
`agents`, `calendar`, `email`, `files`, `hubspot`, `images`, `memory`, `tasks`, `web`, `workflow`

**Access scopes** (from allowlist entry, `settings_user_allowlist_entry.ex:12`): `scopes` field, currently stored but never enforced.

**Proposed scope-to-domain mapping**:

```elixir
@scope_to_skill_domains %{
  "chat" => ["agents", "tasks", "web", "images"],
  "integrations" => ["email", "calendar", "files", "hubspot"],
  "workflows" => ["workflow"],
  "memory" => ["memory"]
}
```

**Note**: "analytics" scope from the plan doesn't map to any skill domain — analytics is a web UI feature only (JSONL viewer). Scope-gate it at the LiveView layer, not the chat engine.

**Default behavior**: If a user has NO scopes configured (empty `access_scopes`), they get FULL access (backwards-compatible). Enforcement only activates when scopes are explicitly set. This prevents breaking existing users who have `access_scopes: []`.

---

## Implementation Spec

### Module Locations and Patterns

#### New Modules

| Module | Path | Pattern |
|--------|------|---------|
| `AccessScopes.Enforcer` | `lib/assistant/access_scopes/enforcer.ex` | Stateless module, `@scope_to_skill_domains` map |
| `SpendingLimits` | `lib/assistant/spending_limits.ex` | Context module (like `SettingsUserConnectorStates`) |
| `SpendingLimits.Enforcer` | `lib/assistant/spending_limits/enforcer.ex` | Pre-flight check, stateless |
| `SpendingLimit` schema | `lib/assistant/schemas/spending_limit.ex` | Follow `SettingsUserConnectorState` pattern |
| `UsageRecord` schema | `lib/assistant/schemas/usage_record.ex` | Follow `SettingsUserConnectorState` pattern |

#### Migrations (3 files)

1. **Add full_name**: `settings_users.full_name` (string, nullable) + `settings_user_allowlist_entries.full_name` (string, nullable)
2. **Create spending_limits**: `settings_user_id` FK to `settings_users`, `budget_cents` integer, `period` string default "monthly", `reset_day` integer default 1, `hard_cap` boolean default true, `warning_threshold` integer default 80
3. **Create usage_records**: `settings_user_id` FK to `settings_users`, `period_start` date, `period_end` date, `total_cost_cents` integer default 0, `total_prompt_tokens` bigint default 0, `total_completion_tokens` bigint default 0, `call_count` integer default 0. Unique index on `[settings_user_id, period_start]`.

#### Modification Points

**`sub_agent.ex` — Scope enforcement** (line ~893):
- Add `AccessScopes.Enforcer.skill_allowed?(dispatch_params.user_id, skill_name)` as new `cond` clause BEFORE `SkillPermissions.enabled_for_user?`
- Error message: generic "not available with your access level" (don't leak scope names)

**`llm_router.ex` — Spending enforcement** (line ~82):
- Add `SpendingLimits.Enforcer.check_budget/1` call at top of `chat_completion/3`
- Accept `:skip_spending_check` opt for sentinel exemption
- On `:over_budget`, return `{:error, :over_budget}` — callers (loop_runner, sub_agent, etc.) must handle this new error variant
- On `{:warning, pct}`, log only (don't interrupt the call)

**`accounts.ex` — Upfront user creation**:
- Add `create_settings_user_from_admin/2` — wraps allowlist upsert + settings_user insert in single transaction
- Add `full_name` to `profile_changeset` cast list
- Extend `sync_matching_settings_user_access/1` to also sync `full_name` if present on allowlist entry

**`settings_user.ex` — Schema changes**:
- Add `field :full_name, :string` to schema
- Add `:full_name` to `profile_changeset` cast + `validate_length(:full_name, max: 160)`

**`settings_user_allowlist_entry.ex` — Schema changes**:
- Add `field :full_name, :string` to schema
- Add `:full_name` to changeset cast list

**`settings_user_auth.ex` — Scope mount hook**:
- Add `on_mount({:require_scope, scope_name}, ...)` clause (see pattern in validation #4 above)
- Admins always bypass scope checks

**`skill_permissions.ex` — No changes needed**. Scope enforcement is a separate layer that runs before SkillPermissions. Don't mix concerns.

**`loop_runner.ex` — Handle `:over_budget` error**:
- Where `LLMRouter.chat_completion` result is matched (~line 88), add `{:error, :over_budget}` clause
- Return budget-exceeded message to user

**`sub_agent.ex` — Handle `:over_budget` error**:
- Where `LLMRouter.chat_completion` result is matched (~line 610), add `{:error, :over_budget}` clause

**`memory/agent.ex`, `memory/compaction.ex`, `memory/turn_classifier.ex`** — Handle `:over_budget`:
- These are internal/background processes. On budget exceeded, fail gracefully (skip compaction/classification, log warning). Don't block background memory operations.

#### Error Handling for `:over_budget`

| Caller | Behavior on `:over_budget` |
|--------|---------------------------|
| `loop_runner.ex` | Return user-facing message: "Your usage limit has been reached for this period." |
| `sub_agent.ex` | Return as skill result: "Unable to complete — usage limit reached." |
| `sentinel.ex` | **Exempt** — skip spending check via `:skip_spending_check` opt |
| `memory/agent.ex` | Log warning, skip operation, return `{:error, :over_budget}` |
| `memory/turn_classifier.ex` | Log warning, return default classification |
| `memory/compaction.ex` | Log warning, skip compaction |

#### AccessScopes.Enforcer Design

```elixir
defmodule Assistant.AccessScopes.Enforcer do
  @moduledoc false

  alias Assistant.Accounts

  @scope_to_skill_domains %{
    "chat" => ["agents", "tasks", "web", "images"],
    "integrations" => ["email", "calendar", "files", "hubspot"],
    "workflows" => ["workflow"],
    "memory" => ["memory"]
  }

  @spec skill_allowed?(String.t() | nil, String.t()) :: boolean()
  def skill_allowed?(user_id, skill_name)

  # No user_id -> allow (system/internal calls)
  def skill_allowed?(nil, _skill_name), do: true
  def skill_allowed?("unknown", _skill_name), do: true

  def skill_allowed?(user_id, skill_name) do
    case Accounts.get_settings_user_by_user_id(user_id) do
      nil -> true  # no settings_user linked = unrestricted (backwards compat)
      settings_user -> authorized?(settings_user, skill_name)
    end
  end

  defp authorized?(settings_user, _skill_name) when settings_user.is_admin == true, do: true

  defp authorized?(settings_user, skill_name) do
    scopes = settings_user.access_scopes || []

    # Empty scopes = unrestricted (backwards compatible)
    if scopes == [] do
      true
    else
      domain = skill_domain(skill_name)
      required_scope = scope_for_domain(domain)

      case required_scope do
        nil -> true  # unmapped domain = no scope gate
        scope -> scope in scopes
      end
    end
  end

  defp skill_domain(skill_name) do
    case String.split(skill_name, ".", parts: 2) do
      [domain, _action] -> domain
      _ -> nil
    end
  end

  defp scope_for_domain(domain) do
    Enum.find_value(@scope_to_skill_domains, fn {scope, domains} ->
      if domain in domains, do: scope
    end)
  end
end
```

#### SpendingLimits.Enforcer Design

```elixir
defmodule Assistant.SpendingLimits.Enforcer do
  @moduledoc false

  alias Assistant.SpendingLimits

  @spec check_budget(String.t() | nil) :: :ok | {:warning, float()} | {:error, :over_budget}
  def check_budget(nil), do: :ok
  def check_budget("unknown"), do: :ok

  def check_budget(user_id) do
    # Bridge chat user_id -> settings_user_id
    case Assistant.Accounts.get_settings_user_by_user_id(user_id) do
      nil -> :ok  # no settings_user = no limits
      settings_user -> SpendingLimits.check_budget(settings_user.id)
    end
  end
end
```

#### SpendingLimits Context

```elixir
# SpendingLimits.check_budget/1 — looks up spending_limit for settings_user_id,
# queries current period usage_record, compares used_cents vs budget_cents.
# Returns :ok | {:warning, pct} | {:error, :over_budget}

# SpendingLimits.record_usage/2 — upsert usage_record for current period.
# Uses Repo.insert with on_conflict: increment atomically.
# Called AFTER LLM call completes (post-flight).

# SpendingLimits.current_usage/1 — returns %{used_cents, budget_cents, pct, period_start, period_end}
# For display in admin UI.
```

#### Usage Recording Integration Points

Post-flight recording happens where analytics are already recorded:
- `loop_runner.ex:281` — `record_llm_analytics` already captures usage map with model, tokens
- `sub_agent.ex:1587` — same pattern

Add `SpendingLimits.record_usage(settings_user_id, usage_map)` alongside existing analytics calls. The `usage_map` already contains `prompt_tokens`, `completion_tokens`, and `model`. For OpenRouter, also extract `cost` from the response (returned in the API response body).

#### Sidebar Scope Gating

In the sidebar component, conditionally render navigation items based on `current_scope.privileges`:

```elixir
# Show section only if admin or scope is in privileges
defp scope_visible?(scope, current_scope) do
  current_scope.admin? or
    current_scope.privileges == [] or  # empty = unrestricted
    scope in current_scope.privileges
end
```

### Implementation Order

```
1. Migrations (database-engineer)
   - full_name columns
   - spending_limits table
   - usage_records table

2. Backend — parallel tracks (backend-coders)
   Track A: Accounts + Schemas
   - full_name on SettingsUser + AllowlistEntry schemas
   - create_settings_user_from_admin/2

   Track B: AccessScopes.Enforcer
   - New module with scope-to-domain mapping
   - Wire into sub_agent.ex cond chain

   Track C: SpendingLimits context + Enforcer
   - SpendingLimit + UsageRecord schemas
   - check_budget, record_usage, current_usage
   - Wire into llm_router.ex (pre-flight)
   - Wire usage recording into loop_runner + sub_agent (post-flight)
   - Handle :over_budget in all 7 LLM callers

3. Frontend (frontend-coder, after backend)
   - on_mount scope hook + router wiring
   - Sidebar scope gating
   - Unified add/edit user page
   - Spending limit admin controls
   - Budget usage display

4. Testing (test-engineer, after frontend)
   - Scope enforcement unit tests
   - Spending limit unit tests
   - Integration tests for upfront user creation
   - LiveView scope gating tests
```

### Key Conventions to Follow

- **Schema location**: `lib/assistant/schemas/` (not `lib/assistant/accounts/`)
- **Schema type annotation**: `@type t :: %__MODULE__{}` (Elixir 1.19 requirement)
- **Primary key**: `@primary_key {:id, :binary_id, autogenerate: true}`
- **FK type**: `@foreign_key_type :binary_id`
- **Timestamps**: `timestamps(type: :utc_datetime_usec)` for new schemas, `:utc_datetime` for schemas in `accounts/`
- **Moduledoc**: `@moduledoc false` for helper/internal modules; real moduledoc for context modules
- **Backwards compatibility**: Empty `access_scopes` = unrestricted access (don't break existing users)
- **Admin bypass**: Admins always bypass scope checks and spending limits
