# Phase 4 Gap Analysis: Gmail, Calendar, and Scheduler

> Prepared: 2026-02-18
> Phase: PREPARE
> Scope: Gmail skills, Google Calendar skills, Scheduler (Quantum + Oban)

---

## Executive Summary

Phase 4 builds Gmail and Calendar integrations on a solid foundation. All four hex dependencies (`google_api_gmail ~> 0.17`, `google_api_calendar ~> 0.26`, `oban ~> 2.18`, `quantum ~> 3.5`) are already declared in `mix.exs`. Oban is fully wired into the supervision tree with four queues (default, compaction, memory, notifications) and has a working Oban worker pattern (`CompactionWorker`). The `Assistant.Scheduler` Quantum module exists but is **not yet added to the supervision tree**. The auth layer (`Google.Auth`), the Drive client pattern, and the skill handler behaviour are all production-ready templates for Gmail/Calendar work. The `Skills.Context` struct already defines `:gmail` and `:calendar` integration slots. The primary work is: (1) add two new integration clients mirroring the Drive client, (2) create six new skill handlers + markdown definitions across two new domains, (3) wire the Quantum scheduler into the supervision tree, (4) add new Oban queues and workers for scheduled jobs, and (5) extend the OAuth scopes in `auth.ex`.

---

## What Exists Today

### Dependencies (mix.exs)

| Dependency | Version Spec | Latest on Hex | Status |
|------------|-------------|---------------|--------|
| `google_api_gmail` | `~> 0.17` | 0.17.0 (Apr 2025) | Declared, not yet used |
| `google_api_calendar` | `~> 0.26` | 0.26.0 (Apr 2025) | Declared, not yet used |
| `oban` | `~> 2.18` | 2.20.3 (Jan 2026) | Active, in supervision tree |
| `quantum` | `~> 3.5` | 3.5.3 (Feb 2024) | Declared, module exists, **NOT in supervision tree** |

All deps are locked and available. No version bumps needed.

### Google Integration Layer

| Component | Path | Status |
|-----------|------|--------|
| `Google.Auth` | `lib/assistant/integrations/google/auth.ex` | Active. Wraps Goth for token management. |
| `Google.Drive` | `lib/assistant/integrations/google/drive.ex` | Active. Template for Gmail/Calendar clients. |
| `Google.Chat` | `lib/assistant/integrations/google/chat.ex` | Active. Uses raw Req HTTP (no GoogleApi library). |

**Auth scopes** (current):
- `https://www.googleapis.com/auth/chat.bot`
- `https://www.googleapis.com/auth/drive.readonly`
- `https://www.googleapis.com/auth/drive.file`

Gmail and Calendar scopes are **not yet included**.

### Skill System

| Component | Path | Status |
|-----------|------|--------|
| `Skills.Handler` behaviour | `lib/assistant/skills/handler.ex` | Stable. `execute(flags, context)` callback. |
| `Skills.Result` struct | `lib/assistant/skills/result.ex` | Stable. `{:ok, %Result{}}` / `{:error, term()}`. |
| `Skills.Context` struct | `lib/assistant/skills/context.ex` | Has `:gmail` and `:calendar` integration slots. |
| File skill handlers | `lib/assistant/skills/files/` | 5 handlers (search, read, write, update, archive). Pattern template. |
| Skill definitions | `priv/skills/files/` | YAML frontmatter + markdown body. `SKILL.md` domain index. |

### Scheduler / Job System

| Component | Path | Status |
|-----------|------|--------|
| `Assistant.Scheduler` | `lib/assistant/scheduler.ex` | Quantum module, `use Quantum, otp_app: :assistant`. |
| Quantum config | `config/config.exs` | `config :assistant, Assistant.Scheduler, jobs: []` |
| Oban config | `config/config.exs` | 4 queues: `default: 10`, `compaction: 5`, `memory: 5`, `notifications: 3` |
| Oban in supervision tree | `lib/assistant/application.ex:34` | `{Oban, Application.fetch_env!(:assistant, Oban)}` |
| `CompactionWorker` | `lib/assistant/scheduler/workers/compaction_worker.ex` | Working Oban worker pattern. |

**Notable**: `Assistant.Scheduler` (Quantum) is defined but **not added as a child** in `application.ex`. It is configured with an empty job list. It needs to be added to the supervision tree before Oban in the child list.

### Supervision Tree Order (current)

```
Config.Loader -> PromptLoader -> Vault -> Repo -> DNSCluster -> PubSub
-> Goth (conditional) -> Oban -> Task.Supervisor -> Skills.Registry
-> Skills.Watcher -> Engine/SubAgent registries -> ConversationSupervisor
-> MemoryAgent -> ContextMonitor -> TurnClassifier -> Notifications.Router
-> Endpoint
```

---

## What Needs to Be Built

### 1. Integration Clients (2 new files)

#### Gmail Client (`lib/assistant/integrations/google/gmail.ex`)

Thin wrapper around `GoogleApi.Gmail.V1` following the Drive client pattern:
- Get a `GoogleApi.Gmail.V1.Connection` via `Google.Auth.token()`
- Key functions needed:
  - `list_messages(query, opts)` -- wraps `gmail_users_messages_list/4` with `q:` parameter
  - `get_message(message_id, opts)` -- wraps `gmail_users_messages_get/5` with format selection
  - `send_message(to, subject, body, opts)` -- wraps `gmail_users_messages_send/4` with RFC 2822 encoding
  - `search_messages(query, opts)` -- convenience alias for `list_messages` with expanded defaults
- Normalize GoogleApi structs into plain maps (same as Drive client pattern)
- User ID should default to `"me"` (service account impersonation via domain-wide delegation)

**Key Gmail API details**:
- Module: `GoogleApi.Gmail.V1.Api.Users`
- Connection: `GoogleApi.Gmail.V1.Connection.new(access_token)`
- List returns only `{id, threadId}` -- requires follow-up `get` for full message content
- Send requires RFC 2822 formatted message, base64url-encoded
- Models: `GoogleApi.Gmail.V1.Model.Message`, `GoogleApi.Gmail.V1.Model.ListMessagesResponse`

#### Calendar Client (`lib/assistant/integrations/google/calendar.ex`)

Thin wrapper around `GoogleApi.Calendar.V3`:
- Get a `GoogleApi.Calendar.V3.Connection` via `Google.Auth.token()`
- Key functions needed:
  - `list_events(calendar_id, opts)` -- wraps `calendar_events_list/4` with time range
  - `get_event(calendar_id, event_id)` -- wraps `calendar_events_get/5`
  - `create_event(calendar_id, event_params)` -- wraps `calendar_events_insert/4`
  - `update_event(calendar_id, event_id, event_params)` -- wraps `calendar_events_update/5`
- Calendar ID defaults to `"primary"` for the impersonated user
- Normalize GoogleApi structs into plain maps

**Key Calendar API details**:
- Module: `GoogleApi.Calendar.V3.Api.Events`
- Connection: `GoogleApi.Calendar.V3.Connection.new(access_token)`
- Events use `EventDateTime` struct with `dateTime` (RFC 3339) or `date` (all-day)
- Models: `GoogleApi.Calendar.V3.Model.Event`, `GoogleApi.Calendar.V3.Model.Events`

### 2. OAuth Scope Additions (`auth.ex`)

Add to `Auth.scopes/0`:
```elixir
"https://www.googleapis.com/auth/gmail.modify"    # read + send + label
"https://www.googleapis.com/auth/calendar"         # full calendar CRUD
```

**Note on `gmail.modify`**: This scope allows reading, sending, and modifying messages/labels but does NOT allow permanent deletion. It is the recommended scope for assistants that need to send and read email without full account control. An alternative is `gmail.send` + `gmail.readonly` if separation is preferred.

### 3. Skill Handlers (6 new handler files)

#### Email Domain (`lib/assistant/skills/email/`)

| Skill | Handler Module | Key Flags |
|-------|---------------|-----------|
| `email.send` | `Email.Send` | `--to`, `--subject`, `--body`, `--cc`, `--bcc` |
| `email.read` | `Email.Read` | `--id` (message ID) |
| `email.search` | `Email.Search` | `--query`, `--from`, `--to`, `--after`, `--before`, `--limit`, `--unread` |

- `email.send` is a **mutating** skill (requires sub-agent delegation + sentinel check)
- `email.read` and `email.search` are **read-only** skills (orchestrator can invoke directly)
- Side effects: `email.send` should report `:email_sent` in `Result.side_effects`

#### Calendar Domain (`lib/assistant/skills/calendar/`)

| Skill | Handler Module | Key Flags |
|-------|---------------|-----------|
| `calendar.list` | `Calendar.List` | `--date`, `--from`, `--to`, `--limit`, `--calendar` |
| `calendar.create` | `Calendar.Create` | `--title`, `--start`, `--end`, `--description`, `--location`, `--attendees`, `--calendar` |
| `calendar.update` | `Calendar.Update` | `--id`, `--title`, `--start`, `--end`, `--description`, `--location`, `--attendees` |

- `calendar.create` and `calendar.update` are **mutating** skills
- `calendar.list` is **read-only**
- Date/time parsing: handlers should accept ISO 8601 strings and natural-language-friendly formats

### 4. Skill Definition Files (8 new markdown files)

```
priv/skills/email/
  SKILL.md          # domain index for email
  send.md           # email.send definition
  read.md           # email.read definition
  search.md         # email.search definition

priv/skills/calendar/
  SKILL.md          # domain index for calendar
  list.md           # calendar.list definition
  create.md         # calendar.create definition
  update.md         # calendar.update definition
```

Each follows the established pattern:
- YAML frontmatter: `name`, `description`, `handler` (module name), `tags`
- Markdown body: description, parameters table, response format, usage notes

### 5. Scheduler Wiring

#### Quantum (cron triggers)

1. Add `Assistant.Scheduler` to supervision tree in `application.ex` -- place before Oban
2. Quantum jobs will be configured via `config/config.exs` and/or added dynamically
3. For Phase 4, a useful default job: daily digest email (if configured)

#### Oban (job workers)

1. Add new queues in `config/config.exs`:
   ```elixir
   queues: [
     default: 10,
     compaction: 5,
     memory: 5,
     notifications: 3,
     email: 5,         # NEW
     calendar: 3,      # NEW
     scheduled: 5      # NEW — general-purpose scheduled jobs
   ]
   ```
2. New worker modules:
   - `Scheduler.Workers.EmailDigestWorker` -- sends daily email summaries
   - `Scheduler.Workers.CalendarReminderWorker` -- sends upcoming event reminders
   - `Scheduler.Workers.ScheduledSkillWorker` -- generic worker that executes a skill on a schedule

### 6. Scheduler Skills (optional, if time permits)

```
priv/skills/scheduler/
  SKILL.md           # domain index
  create.md          # scheduler.create — create a scheduled job
  list.md            # scheduler.list — list scheduled jobs
  cancel.md          # scheduler.cancel — cancel a scheduled job
```

Handler modules in `lib/assistant/skills/scheduler/`.

---

## Dependency Additions Needed

### mix.exs

No changes needed -- all four packages are already declared:
- `{:google_api_gmail, "~> 0.17"}`
- `{:google_api_calendar, "~> 0.26"}`
- `{:oban, "~> 2.18"}`
- `{:quantum, "~> 3.5"}`

### OAuth Scopes (auth.ex)

```elixir
# Add these to Auth.scopes/0
"https://www.googleapis.com/auth/gmail.modify"
"https://www.googleapis.com/auth/calendar"
```

**Important**: If the Goth service account uses domain-wide delegation, these scopes must also be authorized in the Google Workspace Admin console under "Domain-wide Delegation" for the service account's client ID.

---

## Gotchas and Blockers

### Gmail RFC 2822 Encoding

The Gmail send API requires messages in RFC 2822 format, then base64url-encoded. Elixir has no built-in RFC 2822 email builder. Options:
1. **Build minimal RFC 2822 manually** -- simple for text-only messages (just headers + body, no MIME multipart). Recommended for Phase 4.
2. **Use `mail` hex package** -- if richer email composition is needed later.
3. **Use `swoosh`** -- full-featured but heavyweight; overkill for an assistant that sends programmatic emails.

Recommendation: Build a small private function in the Gmail client for RFC 2822 assembly. It is roughly 15 lines for text-only messages.

### Gmail User Impersonation

When using service account with domain-wide delegation, the Gmail API requires specifying which user to impersonate. The `user_id` parameter in API calls should be `"me"`, but Goth must be configured with a `sub` (subject) claim to impersonate a specific user's mailbox. This may require:
- Adding `sub: "user@domain.com"` to the Goth source config in `runtime.exs`
- OR allowing the impersonated user to be configurable per-request (more complex)

For Phase 4, recommend: single impersonated user configured via `GOOGLE_IMPERSONATE_EMAIL` env var.

### Quantum Not in Supervision Tree

`Assistant.Scheduler` exists but is not a child in `application.ex`. Adding it is straightforward but must be placed correctly (after Repo, before Endpoint). The config already has `jobs: []` so it starts cleanly.

### Calendar Time Zones

Google Calendar events include timezone information. The `Context.timezone` field exists and should be used as the default timezone when creating events. If the user does not specify a timezone, fall back to the context timezone, then to UTC.

### Google API Library Dependency on Tesla

The `google_api_*` packages depend on `google_gax` which uses Tesla as the HTTP client (not Req). The project already has `config :tesla, disable_deprecated_builder_warning: true` to suppress warnings. The Drive client works with this setup, so Gmail and Calendar will follow the same pattern.

---

## Recommended Coding Waves

### Wave 1: Foundation (sequential -- blockers for later waves)

| Task | Domain | Files | Notes |
|------|--------|-------|-------|
| Add OAuth scopes | Auth | `lib/assistant/integrations/google/auth.ex` | Add `gmail.modify` + `calendar` scopes |
| Wire Quantum into supervision tree | Scheduler | `lib/assistant/application.ex` | Add `Assistant.Scheduler` as child before Oban |
| Add Oban queues | Config | `config/config.exs` | Add `email: 5`, `calendar: 3`, `scheduled: 5` queues |
| Gmail integration client | Integration | `lib/assistant/integrations/google/gmail.ex` | Model after `drive.ex`. RFC 2822 helper for send. |
| Calendar integration client | Integration | `lib/assistant/integrations/google/calendar.ex` | Model after `drive.ex`. Event normalization. |

**Parallelism**: Gmail client and Calendar client can be built in parallel (no shared files). Auth scope changes and supervision tree wiring are small and can be done by either coder as a precursor.

### Wave 2: Email Skills + Calendar Skills (parallel)

**Email skills** (1 coder):

| Task | Files |
|------|-------|
| `email.search` handler + definition | `lib/assistant/skills/email/search.ex` + `priv/skills/email/search.md` |
| `email.read` handler + definition | `lib/assistant/skills/email/read.ex` + `priv/skills/email/read.md` |
| `email.send` handler + definition | `lib/assistant/skills/email/send.ex` + `priv/skills/email/send.md` |
| Email domain index | `priv/skills/email/SKILL.md` |

**Calendar skills** (1 coder, in parallel):

| Task | Files |
|------|-------|
| `calendar.list` handler + definition | `lib/assistant/skills/calendar/list.ex` + `priv/skills/calendar/list.md` |
| `calendar.create` handler + definition | `lib/assistant/skills/calendar/create.ex` + `priv/skills/calendar/create.md` |
| `calendar.update` handler + definition | `lib/assistant/skills/calendar/update.ex` + `priv/skills/calendar/update.md` |
| Calendar domain index | `priv/skills/calendar/SKILL.md` |

### Wave 3: Scheduler Workers + Skills (parallel)

| Task | Domain | Files |
|------|--------|-------|
| `ScheduledSkillWorker` (generic) | Scheduler | `lib/assistant/scheduler/workers/scheduled_skill_worker.ex` |
| `EmailDigestWorker` | Scheduler | `lib/assistant/scheduler/workers/email_digest_worker.ex` |
| `CalendarReminderWorker` | Scheduler | `lib/assistant/scheduler/workers/calendar_reminder_worker.ex` |
| Scheduler skills (create, list, cancel) | Skills | `lib/assistant/skills/scheduler/` + `priv/skills/scheduler/` |

### Wave 4: Integration Wiring + Env Config

| Task | Files |
|------|-------|
| Wire `:gmail` and `:calendar` into Context building in Executor | `lib/assistant/skills/executor.ex` |
| Add `GOOGLE_IMPERSONATE_EMAIL` env var support | `config/runtime.exs` |
| Update Goth config to support `sub` claim for impersonation | `lib/assistant/application.ex` (in `maybe_goth/0`) |

---

## Compatibility Matrix

| Component | Elixir | OTP | Postgres | Notes |
|-----------|--------|-----|----------|-------|
| `google_api_gmail 0.17.0` | >= 1.11 | >= 22 | N/A | Via `google_gax ~> 0.4` + Tesla |
| `google_api_calendar 0.26.0` | >= 1.11 | >= 22 | N/A | Via `google_gax ~> 0.4` + Tesla |
| `oban 2.18+` | >= 1.13 | >= 25 | >= 12 | Already active |
| `quantum 3.5.3` | >= 1.11 | >= 21 | N/A | Cron parsing only |

Project requires Elixir `~> 1.18` -- all dependencies are compatible.

---

## Security Considerations

1. **Gmail `modify` scope**: Does NOT allow permanent deletion. Messages can only be trashed, labeled, or sent. This is safer than `gmail.full` scope.
2. **Email content**: Messages may contain PII. Handlers should NOT log email body content. Log only message IDs and subjects (truncated).
3. **RFC 2822 injection**: When building email messages, sanitize header values (to, subject, cc) to prevent header injection attacks. Reject newline characters in header fields.
4. **Calendar attendee spoofing**: When creating events with attendees, validate email format to prevent abuse of calendar invitations.
5. **Service account impersonation**: The impersonated email should be a dedicated assistant mailbox, not a personal user account. This limits blast radius.

---

## Source References

- [google_api_gmail on Hex.pm](https://hex.pm/packages/google_api_gmail) -- v0.17.0
- [google_api_calendar on Hex.pm](https://hex.pm/packages/google_api_calendar) -- v0.26.0
- [Oban on Hex.pm](https://hex.pm/packages/oban) -- v2.20.3
- [Quantum on Hex.pm](https://hex.pm/packages/quantum) -- v3.5.3
- [GoogleApi.Gmail.V1.Api.Users](https://hexdocs.pm/google_api_gmail/0.17.0/GoogleApi.Gmail.V1.Api.Users.html) -- message list/get/send functions
- [GoogleApi.Calendar.V3.Api.Events](https://hexdocs.pm/google_api_calendar/0.26.0/GoogleApi.Calendar.V3.Api.Events.html) -- event CRUD functions
