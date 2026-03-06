# Integration Plan: Codex Admin Worktree → Main

> Generated: 2026-03-05
> Status: APPROVED
> Codex worktree: `/Users/jrosenbaum/.codex/worktrees/5a2c/Synaptic-Assistant`
> Branch: `codex/admin-panel-connector-config-5a2c`
> Base plan: `docs/plans/admin-first-connectors-plan.md`

## Context

PR #45 merged admin-only model management + LLM router fix + per-user skill overrides to main.
The Codex worktree has extensive uncommitted work implementing the admin-first connectors plan
(integration detail pages, card toggles, sidebar cleanup, personal skill overrides UI, etc.).
These two streams need to be reconciled.

## Key Design Decisions (User-Specified)

1. **"Models" sidebar section is REMOVED** — all model management (Model Providers, Role Defaults, Active Model List) moves into the Admin section
2. **"Skill Permissions" sidebar section is REMOVED** — personal tool access lives in app card settings (per the connectors plan)
3. **Fallback model is PER ROLE, not global** — each role (orchestrator, sub_agent, sentinel, compaction) gets a primary model AND a fallback model dropdown. Remove the single `:model_default_fallback` registry key.
4. **Work in the Codex worktree** — do not create a new worktree

---

## File-by-File Plan

### Legend
- **USE MAIN** = Main's version is correct, no change needed
- **USE CODEX** = Port Codex's version onto main
- **MERGE** = Both changed the file, need to combine
- **NEW WORK** = Neither version is complete, new changes needed

---

### 1. One-line fix

| File | Detail |
|------|--------|
| `lib/assistant/skill_permissions.ex` | Line 131: Codex has `default: false` for hubspot connector gate; Main has `default: true`. Codex is correct — connectors should default to disabled until user explicitly enables. |

### 2. Schemas/migrations — already on main from PR #45 (USE MAIN)

PR #45 versions are more complete (have `@type t` for Elixir 1.19, `validate_known_skill`, DateTime truncation fix).

| File | Action |
|------|--------|
| `lib/assistant/schemas/settings_user_connector_state.ex` | USE MAIN |
| `lib/assistant/schemas/user_skill_override.ex` | USE MAIN |
| `lib/assistant/settings_user_connector_states.ex` | USE MAIN |
| `lib/assistant/user_skill_overrides.ex` | USE MAIN |
| `priv/repo/migrations/20260305110000_create_settings_user_connector_states.exs` | USE MAIN |
| `priv/repo/migrations/20260305110001_create_user_skill_overrides.exs` | USE MAIN |
| `docs/plans/admin-first-connectors-plan.md` | USE CODEX (copy to main, just a doc) |

### 3. New files from Codex — port to main

| File | Detail |
|------|--------|
| `test/assistant/skill_permissions_user_overrides_test.exs` | New test for per-user skill overrides |
| `test/assistant_web/live/settings_live/admin_integration_detail_test.exs` | New test for admin integration detail pages |

### 4. Files modified ONLY in Codex (main untouched) — port directly

| File | Detail |
|------|--------|
| `lib/assistant/channels/user_resolver.ex` | Formatting changes (multi-line args) |
| `lib/assistant/workspace.ex` | Small change |
| `lib/assistant_web/components/admin_integrations.ex` | Modified to accept `group_filter` param |
| `lib/assistant_web/components/settings_page.ex` | Updated section rendering (adds admin integration detail view) |
| `lib/assistant_web/components/settings_page/app_detail.ex` | Removed non-admin credential inputs, added personal tool access |
| `lib/assistant_web/components/settings_page/apps.ex` | Card toggles, settings icon, connector state integration |
| `lib/assistant_web/controllers/oauth_controller.ex` | Small change |
| `lib/assistant_web/live/settings_live/context.ex` | Small change |
| `lib/assistant_web/router.ex` | Added `/settings/admin/integrations/:integration_group` route |
| `priv/repo/migrations/20260304200001_add_email_to_users.exs` | Modified existing migration |
| `priv/repo/migrations/20260304200004_add_left_at_to_user_identities.exs` | Modified existing migration |
| `test/assistant/channels/google_chat_test.exs` | Test updates |
| `test/assistant/channels/space_context_fanout_worker_test.exs` | Test updates |
| `test/assistant/workspace_space_context_test.exs` | Test updates |
| `test/assistant_web/live/settings_live/ensure_linked_user_test.exs` | Test updates |
| `test/assistant_web/live/settings_live/telegram_connector_test.exs` | Test updates |

### 5. Files modified in BOTH Codex and Main — need merge

| File | Main has | Codex has | Merge strategy |
|------|----------|-----------|----------------|
| `lib/assistant/memory/agent.ex` | `enabled_for_user?` call (PR #45) | Formatting changes | Keep PR #45 `enabled_for_user?`, apply Codex formatting |
| `lib/assistant/orchestrator/sub_agent.ex` | `enabled_for_user?` call (PR #45) | Formatting changes | Keep PR #45 `enabled_for_user?`, apply Codex formatting |
| `lib/assistant/schemas/user.ex` | PR #45 changes | Codex changes (email field?) | Combine both |
| `lib/assistant_web/controllers/google_chat_controller.ex` | PR #45 removed thinking messages | Codex has different changes | Review and combine |
| **`lib/assistant_web/components/settings_page/admin.ex`** | Model Providers + Role Defaults | Integration catalog + detail pages | **BIG MERGE**: Combine integration catalog grid + model management into admin. Active Model List moves here too (from models.ex). |
| **`lib/assistant_web/components/settings_page/helpers.ex`** | Still has "models" + "skills" nav | Codex removed "skills" | Remove BOTH "models" and "skills" from nav |
| **`lib/assistant_web/live/settings_live/data.ex`** | Has `skills` section | Codex removed `skills`, added `admin_integration_catalog` | Use Codex + remove "models" from `@sections` |
| **`lib/assistant_web/live/settings_live/events.ex`** | Admin gate on `toggle_skill_permission` | Connector toggle events, personal skill toggle | Combine both sets of event handlers |
| **`lib/assistant_web/live/settings_live/loaders.ex`** | Model data in admin loader | `load_connector_states`, `load_personal_skill_permissions`, `load_app_detail_settings`, `load_admin_integration_settings` | Admin loader needs BOTH model data AND integration settings. Apps loader needs connector states. Remove standalone `load_section_data("skills")`. Models loading moves to admin loader. |
| **`lib/assistant_web/live/settings_live/state.ex`** | PR #45 model assigns | `connector_states`, `personal_skill_permissions`, `current_admin_integration`, `admin_integration_catalog` | Combine all assigns |

### 6. Files only on main (PR #45) — keep or redesign

| File | Action | Note |
|------|--------|------|
| `lib/assistant/behaviours/llm_router.ex` | USE MAIN | LLM router behaviour |
| `lib/assistant/integrations/llm_router.ex` | USE MAIN | Credential-based routing |
| `lib/assistant/config/loader.ex` | **NEW WORK** | `resolve_fast_model` cascade needs redesign for per-role fallback |
| `lib/assistant/integration_settings/registry.ex` | **NEW WORK** | Remove `:model_default_fallback`. Add per-role fallback keys: `:model_default_orchestrator_fallback`, `:model_default_sub_agent_fallback`, `:model_default_sentinel_fallback`, `:model_default_compaction_fallback` |
| `lib/assistant/model_defaults.ex` | **NEW WORK** | Add per-role fallback support. `@role_keys` and `@global_setting_keys` need fallback variants per role. |
| `lib/assistant/orchestrator/sentinel.ex` | USE MAIN | Already uses `resolve_fast_model` |
| `lib/assistant/memory/turn_classifier.ex` | USE MAIN | Already uses `resolve_fast_model` |
| `lib/assistant_web/components/settings_page/models.ex` | **MERGE into admin.ex** | Active Model List component moves into admin section. This file may become empty/deleted after move. |

### 7. New work required (beyond porting)

| Change | Files affected | Detail |
|--------|---------------|--------|
| **Per-role fallback model** | `registry.ex`, `model_defaults.ex`, `config/loader.ex`, `loaders.ex`, admin UI | Each role gets primary + fallback. Remove single `:model_default_fallback`. Add 4 fallback keys. Update `resolve_fast_model` cascade: role-specific → role-fallback → `models_by_tier(:fast)`. Update `model_roles` in loaders to include fallback entries. UI shows 2 dropdowns per role (primary + fallback). |
| **Move Models into Admin** | `helpers.ex`, `data.ex`, `admin.ex`, `models.ex`, `loaders.ex`, `state.ex` | Remove "models" from nav items. Move Active Model List + Add Model modal + Model Providers + Role Defaults into admin section. `load_section_data("models")` merges into `load_admin`. |
| **Remove Skills from sidebar** | `helpers.ex`, `data.ex`, `loaders.ex` | Already done in Codex. Port to main. Remove `load_section_data("skills")` clause. |

---

## Execution Order

### Phase 1: Port Codex-only changes (no conflicts)
All Category 4 files — direct port from Codex to main.

### Phase 2: Merge conflict files
The 10 Category 5 files — combine PR #45 and Codex changes.
Priority order (dependencies):
1. `data.ex` + `helpers.ex` (nav/section structure)
2. `state.ex` (all assigns)
3. `loaders.ex` (data loading)
4. `events.ex` (event handlers)
5. `admin.ex` + `settings_page.ex` (UI components)
6. `sub_agent.ex` + `memory/agent.ex` + `user.ex` + `google_chat_controller.ex`

### Phase 3: Move Models into Admin
Remove "models" sidebar section, consolidate into admin.

### Phase 4: Per-role fallback redesign
Registry keys, ModelDefaults, ConfigLoader, UI dropdowns.

### Phase 5: Compile + test
Verify compilation, run full test suite, fix any issues.

---

## Fallback Model Cascade (Per-Role Design)

For each role (e.g., `:orchestrator`):
```
1. model_default_orchestrator          (primary — admin-set)
2. model_default_orchestrator_fallback (fallback — admin-set)
3. models_by_tier(:fast)               (system tier — hardcoded last resort)
```

UI in Admin > Role Defaults:
```
Orchestrator:   [Primary dropdown ▼]  [Fallback dropdown ▼]
Subagents:      [Primary dropdown ▼]  [Fallback dropdown ▼]
Sentinel:       [Primary dropdown ▼]  [Fallback dropdown ▼]
Memory:         [Primary dropdown ▼]  [Fallback dropdown ▼]
```

Registry keys to add (in "models" group):
- `:model_default_orchestrator_fallback`
- `:model_default_sub_agent_fallback`
- `:model_default_sentinel_fallback`
- `:model_default_compaction_fallback`

Registry key to remove:
- `:model_default_fallback` (the single global one from PR #45)
