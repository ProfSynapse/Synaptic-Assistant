# Markdown-First Skill Definition System: Architectural Design

> Part of the Skills-First AI Assistant architecture.
> **Supersedes** the JSON Schema tool-calling pattern from `two-tool-architecture.md`.
> Planning only — no implementation.
>
> **Revision 3** — Dot notation + `.all` suffix per user direction:
> - Skill names use dot notation: `domain.action` (e.g., `email.send`, `tasks.search`)
> - `get_skill` uses dot notation: `get_skill: email.send`
> - `.all` suffix loads entire domain: `get_skill: email.all`
> - Each domain folder has a `SKILL.md` index file

## 1. Overview

### 1.1 The Paradigm Shift

The previous architecture defined skills as Elixir modules with JSON Schema tool definitions, invoked via OpenRouter's structured tool-calling format (`get_skill`/`use_skill`). This design replaces that with a fundamentally different approach:

**Skills are markdown files.** Each file defines exactly one atomic action. Minimal YAML frontmatter provides the machine-readable identity (`name`, `description`). The markdown body is the full definition: usage syntax, flags, behavior instructions, and examples — like a Unix man page.

| Aspect | Previous (JSON Schema) | New (Markdown) |
|--------|----------------------|----------------|
| Skill definition | Elixir module with `tool_definition/0` | Markdown file (man-page style) |
| Skill schema | JSON Schema in YAML frontmatter | Usage/Flags sections in markdown body |
| LLM interaction | JSON tool calls (`use_skill(...)`) | CLI command strings in ` ```cmd ` blocks |
| Discovery | `get_skill` meta-tool | `get_skill` with dot notation (`get_skill: email.send`) |
| Skill creation | Write Elixir code, compile, deploy | Write a markdown file |
| Registration | Compile-time module discovery | Runtime file discovery (watch directory) |
| Granularity | One module per domain (multiple actions) | **One file per action** (SRP) |

### 1.2 Why This Approach

**Natural for LLMs**: LLMs are trained on massive CLI documentation. They produce well-formed CLI commands more reliably than nested JSON. `email.draft --to bob@co.com --subject "Q1 Report" --body "Here is the report."` is more natural than `{"skill": "email.draft", "arguments": {"to": "bob@co.com", ...}}`.

**Self-documenting**: Each skill file IS its own documentation. The markdown body can be served directly as `--help` output. No schema-to-natural-language translation needed.

**Self-creating**: Users and the assistant can create new skills by writing markdown files. No Elixir code needed for the definition — only a handler module for built-in skills.

**SRP / Atomic**: One file = one action. `email/send.md` does exactly one thing: send an email. No subcommands, no multi-action files. This makes skills composable, testable, and replaceable.

**Minimal metadata**: YAML frontmatter contains only what machines need for routing (`name`, `description`). Everything else — usage, flags, behavior — lives in human-readable markdown.

### 1.3 Architecture Summary

```
User message
    |
    v
Orchestrator LLM
    |
    v
Outputs CLI command(s) in ```cmd blocks
    |
    v
CLI Extractor (Elixir)
  - Detects ```cmd fenced blocks in LLM output
  - Separates commands from conversational text
    |
    v
Skill Router
  - Matches command name to skill file
  - Passes raw command string + parsed flags to handler
    |
    v
Handler Module (Elixir)
  - Built-in: Executes the action (API call, DB query, etc.)
  - Custom: Returns template for LLM to interpret
    |
    v
Result returned to LLM context
```

---

## 2. Skill File Format

### 2.1 Design Principle: Minimal YAML, Rich Markdown

The YAML frontmatter is deliberately minimal — only what the registry needs for routing and discovery. Everything the LLM or user needs to understand the skill lives in the markdown body.

**Why?**
- YAML is for machines (registry, routing, scheduling)
- Markdown is for humans and LLMs (understanding, help text, behavior)
- Mixing detailed schemas into YAML creates a parallel definition that drifts from the human-readable docs
- The markdown body IS the source of truth — it is served directly as help output

### 2.2 YAML Frontmatter (Minimal)

```yaml
---
name: <domain.action>             # Required. Dot notation: domain.action (e.g., email.send)
description: <one-line summary>   # Required. Shown in skill listings and search results
---
```

That's it. Two fields. The registry needs the name for routing and the description for discovery listings.

**Optional frontmatter fields** (added only when needed):

| Field | When Used | Purpose |
|-------|-----------|---------|
| `handler` | Built-in skills | Elixir module that executes this skill |
| `schedule` | Scheduled skills | Cron expression for Quantum |
| `author` | Custom skills | Who created the skill |
| `created` | Custom skills | Creation date |
| `tags` | All skills | Searchable tags for skill discovery |

```yaml
---
name: email.send
description: Send an email to one or more recipients
handler: Assistant.Skills.Email.Send
tags: [email, communication]
---
```

### 2.3 Markdown Body (The Full Definition)

The markdown body follows a man-page convention. Sections are parsed by the system for help text generation and (optionally) flag extraction:

```markdown
# <skill_name>

<Extended description — what this skill does, when to use it>

## Usage

<command> --flag <value> [--optional-flag <value>]

## Flags

--flag-name    Description of the flag (required)
--other-flag   Description (default: value)
--enum-flag    Description. One of: option1, option2, option3

## Behavior

<Instructions for the handler or LLM — what to do, edge cases, constraints>

## Examples

<skill_name> --flag value --other-flag value
<skill_name> --flag "value with spaces"
```

### 2.4 Example: Built-In Skill (`email/send.md`)

```markdown
---
name: email.send
description: Send an email to one or more recipients
handler: Assistant.Skills.Email.Send
---

# email.send

Send an email via Gmail. Supports multiple recipients, CC/BCC, and file attachments
from Google Drive.

## Usage

email.send --to <addresses> --subject <text> --body <text> [--cc <addresses>] [--bcc <addresses>] [--attachments <file_ids>]

## Flags

--to            Recipient email addresses, space-separated (required)
--subject       Email subject line (required)
--body          Email body text, supports markdown formatting (required)
--cc            CC recipients, space-separated
--bcc           BCC recipients, space-separated
--attachments   Google Drive file IDs to attach, space-separated

## Behavior

Send the email immediately via Gmail API. Return the message ID on success.
Multiple recipients: --to alice@co.com bob@co.com
Attachments are Google Drive file IDs (use drive.search to find them).

## Examples

email.send --to bob@company.com --subject "Q1 Report" --body "Here is the Q1 report."
email.send --to alice@co.com bob@co.com --subject "Meeting Notes" --body "Attached." --attachments file123
```

### 2.5 Example: Built-In Skill (`tasks/search.md`)

```markdown
---
name: tasks.search
description: Search and filter tasks by status, assignee, priority, tags, or text
handler: Assistant.Skills.Tasks.Search
---

# tasks.search

Search and filter the task list. Combines text search with structured filters.

## Usage

tasks.search [--query <text>] [--status <statuses>] [--assignee <name>] [--priority <levels>] [--tags <tags>] [--overdue] [--sort <field>] [--limit <n>]

## Flags

--query       Free text search across task titles and descriptions
--status      Filter by status. One or more of: todo, in_progress, blocked, done, cancelled (default: todo, in_progress, blocked)
--assignee    Filter by assignee name
--priority    Filter by priority. One or more of: critical, high, medium, low
--tags        Filter by tags. Tasks must have ALL specified tags
--due-before  Tasks due on or before this date (YYYY-MM-DD)
--due-after   Tasks due on or after this date (YYYY-MM-DD)
--overdue     Only show tasks past their due date (boolean flag)
--sort        Sort by: due_date, priority, created_at, updated_at (default: due_date)
--limit       Maximum number of results (default: 20)

## Behavior

With no flags, returns active tasks (todo, in_progress, blocked) for the current user,
sorted by due date. All filters are AND-combined except --status and --priority which
accept multiple values (OR within the filter).

## Examples

tasks.search --status overdue --assignee me
tasks.search --tags Q1 backend --priority high critical
tasks.search --query "marketing report" --due-before 2026-03-01
```

### 2.6 Example: Workflow (`workflows/daily_digest.md`)

Workflows are compositions of existing skills, created by the assistant or user. They typically have no handler — the markdown body contains instructions for the LLM to interpret and execute as a sequence of skill invocations.

```markdown
---
name: workflows.daily_digest
description: Generate and send the 8am daily digest email
schedule: "0 8 * * 1-5"
author: assistant
created: 2026-02-17
---

# workflows.daily_digest

Generate and send the morning daily digest. Collects overdue tasks, today's calendar
events, and unread important emails.

## Usage

workflows.daily_digest [--recipient <email>] [--include-weather]

## Flags

--recipient       Who receives the digest (default: me)
--include-weather Include weather summary (boolean flag)

## Behavior

Execute these steps in order:

1. Search for overdue and today's tasks:
   tasks.search --overdue --sort priority
   tasks.search --due-before {today} --due-after {today} --sort priority

2. Get today's calendar events:
   calendar.list --date {today}

3. Search for unread important emails (last 24h):
   email.search --unread --after {yesterday} --label important --limit 5

4. Compose and send the digest:
   email.send --to {recipient} --subject "Daily Digest - {today}" --body "{compiled_digest}"

## Examples

workflows.daily_digest
workflows.daily_digest --recipient bob@company.com --include-weather
```

### 2.7 Example: Skill with Behavior Instructions (`email/draft.md`)

```markdown
---
name: email.draft
description: Draft an email for review before sending
handler: Assistant.Skills.Email.Draft
---

# email.draft

Draft an email and return it for user review. Does NOT send the email.

## Usage

email.draft --to <recipient> --subject <subject> --body <body> [--tone <tone>]

## Flags

--to        Recipient email address (required)
--subject   Email subject line (required)
--body      Email body content (required)
--tone      Writing tone: formal, casual, friendly (default: professional)

## Behavior

Draft the email and return it for user review. Do NOT send.
Format the draft clearly so the user can see exactly what will be sent.
Apply the requested tone to the body text.
If the user approves, they will follow up with email.send.

## Examples

email.draft --to bob@co.com --subject "Q1 Report" --body "Summary of Q1 results"
email.draft --to alice@co.com --subject "Coffee?" --body "Want to grab coffee?" --tone casual
```

---

## 3. Directory Structure (SRP)

### 3.1 One File Per Action + Domain Index

Each skill file defines exactly ONE atomic action. Domain grouping is achieved through directory structure. Each domain folder contains a `SKILL.md` index file that provides the domain overview for progressive discovery.

```
skills/
├── email/
│   ├── SKILL.md           # Domain index: "Email tools for Gmail integration"
│   ├── send.md            # email.send
│   ├── search.md          # email.search
│   ├── read.md            # email.read
│   └── draft.md           # email.draft
├── tasks/
│   ├── SKILL.md           # Domain index: "Task management and tracking"
│   ├── create.md          # tasks.create
│   ├── search.md          # tasks.search
│   ├── get.md             # tasks.get
│   ├── update.md          # tasks.update
│   └── delete.md          # tasks.delete
├── calendar/
│   ├── SKILL.md           # Domain index: "Google Calendar event management"
│   ├── create.md          # calendar.create
│   ├── list.md            # calendar.list
│   └── update.md          # calendar.update
├── drive/
│   ├── SKILL.md           # Domain index
│   ├── read.md            # drive.read
│   ├── update.md          # drive.update
│   ├── list.md            # drive.list
│   └── search.md          # drive.search
├── hubspot/
│   ├── SKILL.md           # Domain index
│   ├── contacts.md        # hubspot.contacts
│   ├── deals.md           # hubspot.deals
│   └── notes.md           # hubspot.notes
├── memory/
│   ├── SKILL.md           # Domain index
│   ├── save.md            # memory.save
│   └── search.md          # memory.search
├── markdown/
│   ├── SKILL.md           # Domain index
│   ├── edit.md            # markdown.edit
│   ├── create.md          # markdown.create
│   └── search.md          # markdown.search
├── workflow/               # Meta-skills for workflow management
│   ├── SKILL.md           # Domain index
│   └── build.md           # workflow.build
└── workflows/             # User/assistant-created workflows (compositions of skills)
    ├── SKILL.md           # Domain index (auto-updated on workflow creation)
    ├── daily_digest.md    # workflows.daily_digest
    └── weekly_report.md   # workflows.weekly_report
```

### 3.2 SKILL.md — Domain Index File

Each domain folder contains a `SKILL.md` that serves as the domain-level discovery document. This is what `get_skill: email` returns — the progressive disclosure layer between "list all domains" and "show me a specific skill."

**Format**:

```markdown
---
domain: email
description: Email tools for Gmail integration
---

# Email

Send, read, search, and draft emails via Gmail.

## Available Skills

| Skill | Description |
|-------|-------------|
| email.send | Send an email to one or more recipients |
| email.search | Search emails by query, sender, date range |
| email.read | Read a specific email by ID |
| email.draft | Draft an email for review before sending |

## Common Patterns

- Send an email: `email.send --to bob@co.com --subject "Hi" --body "Hello"`
- Find recent emails: `email.search --query "Q1 report" --after 2026-02-01`
- Draft for review: `email.draft --to alice@co.com --subject "Proposal" --body "..." --tone formal`

## Notes

- All email operations use the Gmail API via OAuth2
- Attachments are Google Drive file IDs (use drive.search to find them)
- Body text supports markdown formatting
```

**Example: tasks/SKILL.md**:

```markdown
---
domain: tasks
description: Task management and tracking
---

# Tasks

Create, search, update, and manage tasks with priorities, due dates, tags, and assignments.

## Available Skills

| Skill | Description |
|-------|-------------|
| tasks.create | Create a new task with title, priority, due date |
| tasks.search | Search and filter tasks by status, assignee, priority, tags |
| tasks.get | Get full details of a specific task by ID |
| tasks.update | Update task status, priority, assignee, or other fields |
| tasks.delete | Archive a task (soft delete) |

## Common Patterns

- Create a task: `tasks.create --title "Review PR" --priority high --due 2026-02-20`
- Find overdue tasks: `tasks.search --overdue --sort priority`
- Update status: `tasks.update --id TASK_ID --status done`

## Notes

- Tasks support dependencies via parent/child relationships
- Assignee "me" resolves to the current user
- Default status for new tasks is "todo"
```

### 3.3 Progressive Disclosure via Dot Notation

The `get_skill` command uses **dot notation** that maps directly to the folder/file structure:

```
Dot notation:  domain.command  →  skills/{domain}/{command}.md
```

Three tiers of progressive disclosure:

```
Level 1: get_skill — No arguments
  -> Lists all domain SKILL.md summaries (domain name + description)
  -> "Email: Email tools for Gmail integration"
  -> "Tasks: Task management and tracking"
  -> etc.

Level 2: get_skill: memory — Domain only (dot notation, single segment)
  -> Resolves to memory/SKILL.md
  -> Returns full domain index (available skills, patterns, notes)
  -> LLM now knows memory.save, memory.search, etc. exist

Level 3: get_skill: memory.search — Domain + command (dot notation, two segments)
  -> Resolves to memory/search.md
  -> Returns full skill markdown body (usage, flags, behavior, examples)
  -> LLM now knows exact flags and syntax

Level 3b: get_skill: email.all — Domain + ".all" suffix
  -> Resolves to all .md files in email/ (excluding SKILL.md)
  -> Returns concatenated content of every skill in the domain
  -> Useful when the LLM needs the full domain reference at once
```

The dot notation provides a uniform, predictable addressing scheme:
- `email.send` always resolves to `skills/email/send.md`
- `email` resolves to `skills/email/SKILL.md`
- `email.all` resolves to all `skills/email/*.md` (excluding `SKILL.md`)

The LLM moves from broad (all domains) to narrow (specific skill flags) as needed. The `.all` suffix is for cases where the LLM wants to load an entire domain at once (e.g., first time using a domain, or complex multi-skill tasks).

### 3.4 SKILL.md Auto-Generation for Custom Domain

When a workflow is created via `workflow.build`, the `workflows/SKILL.md` is auto-updated to include the new workflow in its Available Skills table:

```elixir
defp update_workflows_index(new_workflow) do
  workflows = Registry.list_by_domain("workflows")
  content = generate_domain_index("workflows", "User/assistant-created workflows", workflows)
  File.write!(Path.join(@skills_dir, "workflows/SKILL.md"), content)
end
```

### 3.5 Naming Convention

- **File names**: `<verb>.md` or `<descriptive_name>.md` — reflect the action
- **Domain index**: Always `SKILL.md` (uppercase, distinguishes from skill files)
- **Skill names** (in YAML `name` field): `<domain>.<command>` dot notation — e.g., `email.send`, `tasks.search`, `calendar.create`
- **Directory names**: Domain grouping — `email/`, `tasks/`, `calendar/`, etc.
- Skill names are globally unique — domain + command is unique by filesystem constraint

### 3.6 Domain Derivation

The domain is derived from the directory path, not from YAML frontmatter:

```elixir
# skills/email/send.md -> domain: "email"
# skills/tasks/create.md -> domain: "tasks"
# skills/workflows/daily_digest.md -> domain: "workflows"
# skills/email/SKILL.md -> skipped (domain index, not a skill)
defp derive_domain(file_path, skills_root) do
  file_path
  |> Path.relative_to(skills_root)
  |> Path.dirname()
  |> String.split("/")
  |> List.first()
end
```

---

## 4. CLI Extractor

### 4.1 LLM Output Format

The LLM outputs CLI commands inside ` ```cmd ` fenced blocks. Text outside blocks is the conversational response:

```
I'll search for your overdue tasks and send them to Bob.

```cmd
tasks.search --status overdue --assignee me
```

Found 3 overdue tasks. Sending the report now.

```cmd
email.send --to bob@co.com --subject "Overdue Tasks Report" --body "Here are the 3 overdue tasks: ..."
```

Done! Report sent to Bob.
```

### 4.2 Extractor Module

```elixir
defmodule Assistant.CLI.Extractor do
  @cmd_fence_regex ~r/```cmd\n(.*?)\n```/s

  @doc """
  Extract CLI commands from LLM output text.
  Returns commands (list of strings) and remaining text.
  """
  def extract_commands(llm_output) do
    commands = Regex.scan(@cmd_fence_regex, llm_output)
      |> Enum.map(fn [_full, content] -> String.trim(content) end)
      |> Enum.flat_map(&String.split(&1, "\n", trim: true))

    text = Regex.replace(@cmd_fence_regex, llm_output, "")
      |> String.trim()

    %{commands: commands, text: text}
  end
end
```

---

## 5. Command Routing and Execution

### 5.1 Two Approaches to Flag Handling

The simplified skill format creates a design choice for how commands are parsed and validated:

**Approach A: Handler validates (recommended)**

The router resolves the skill name, tokenizes the raw command string, and passes both the raw string and a best-effort parsed flags map to the handler. The handler is responsible for validation.

```
"email.send --to bob@co.com --subject \"Q1 Report\" --body \"See attached.\""
    |
    v
Tokenizer (shell-style)
  -> ["email.send", "--to", "bob@co.com", "--subject", "Q1 Report", "--body", "See attached."]
    |
    v
Router: match "email.send" -> skills/email/send.md
    |
    v
Generic flag parser (best-effort, no schema):
  -> %{"to" => "bob@co.com", "subject" => "Q1 Report", "body" => "See attached."}
    |
    v
Handler: Assistant.Skills.Email.Send.execute(flags, context)
  - Handler knows its own required/optional fields
  - Handler validates types, enums, defaults
  - Handler returns {:ok, result} or {:error, reason}
```

**Approach B: Parser extracts flag definitions from markdown**

The parser reads the `## Flags` section of the markdown body, builds a schema from the text, and validates flags before calling the handler. More complex parsing but centralizes validation.

```
"email.send --to bob@co.com --subject \"Q1 Report\" --body \"See attached.\""
    |
    v
Router: match "email.send" -> skills/email/send.md
    |
    v
Read ## Flags section from markdown body
  -> Parse flag definitions: --to (required), --subject (required), --body (required), etc.
    |
    v
Flag parser (schema-aware):
  -> Validate: all required flags present? Types correct?
  -> %{"to" => "bob@co.com", "subject" => "Q1 Report", "body" => "See attached."}
    |
    v
Handler: Assistant.Skills.Email.Send.execute(flags, context)
```

### 5.2 Recommended: Approach A (Handler Validates)

**Why**: Keeps the system simple. The markdown body is for humans and LLMs, not for machine parsing. Extracting structured schemas from free-text flag descriptions is fragile and creates a hidden coupling between documentation formatting and system behavior. Handlers already know their requirements — let them validate.

**Trade-off**: Validation error messages come from handler code, not from a centralized parser. This means each handler must produce clear error messages. This is acceptable because:
- Built-in handlers are Elixir modules written by developers — they can produce good errors
- Custom skills (no handler) are interpreted by the LLM, which reads the Flags section directly
- A common validation helper module avoids duplicating validation logic across handlers

### 5.3 Router Module

```elixir
defmodule Assistant.Skills.Router do
  @doc """
  Route a raw command string to the appropriate skill handler.
  """
  def route(command_string) do
    with {:ok, tokens} <- tokenize(command_string),
         {:ok, skill_name, rest_tokens} <- extract_skill_name(tokens),
         {:ok, skill_def} <- Registry.lookup(skill_name) do

      flags = parse_flags_best_effort(rest_tokens)

      {:ok, %RoutedCommand{
        skill_name: skill_name,
        skill_def: skill_def,
        flags: flags,
        raw: command_string,
        rest_tokens: rest_tokens
      }}
    end
  end

  @doc """
  Shell-style tokenization. Respects quoted strings.
  """
  def tokenize(input) do
    {:ok, do_tokenize(String.trim(input), [], "")}
  end

  defp extract_skill_name([name | rest]) do
    if Registry.skill_exists?(name) do
      {:ok, name, rest}
    else
      {:error, {:unknown_skill, name}}
    end
  end

  @doc """
  Best-effort flag parsing without a schema.
  Extracts --key value pairs. No type casting or validation.
  """
  defp parse_flags_best_effort(tokens) do
    do_parse(tokens, %{})
  end

  defp do_parse([], acc), do: acc

  defp do_parse(["--" <> flag_name | rest], acc) do
    {values, remaining} = collect_values(rest)
    case values do
      [] -> do_parse(remaining, Map.put(acc, flag_name, true))  # boolean flag
      [single] -> do_parse(remaining, Map.put(acc, flag_name, single))
      multiple -> do_parse(remaining, Map.put(acc, flag_name, multiple))
    end
  end

  defp do_parse([_positional | rest], acc) do
    # Ignore unexpected positional args in best-effort mode
    do_parse(rest, acc)
  end

  defp collect_values(tokens) do
    Enum.split_while(tokens, fn t -> not String.starts_with?(t, "--") end)
  end
end
```

### 5.4 Execution Pipeline

```elixir
defmodule Assistant.Skills.Executor do
  @doc """
  Execute a routed command.
  Built-in skills: call handler module.
  Custom skills: return template for LLM interpretation.
  """
  def execute(%RoutedCommand{} = cmd, context) do
    case cmd.skill_def do
      %{handler: handler} when not is_nil(handler) ->
        # Built-in skill: call handler directly
        handler.execute(cmd.flags, context)

      %{handler: nil} = skill_def ->
        # Custom skill: return the markdown body for LLM interpretation
        {:ok, %SkillResult{
          status: :ok,
          content: skill_def.body,
          metadata: %{type: :template, requires_interpretation: true}
        }}
    end
  end
end
```

### 5.5 Handler Behaviour

```elixir
defmodule Assistant.Skills.Handler do
  @doc """
  Execute the skill with parsed CLI flags and execution context.
  The handler is responsible for validating flags (required fields, types, enums).
  """
  @callback execute(flags :: map(), context :: Assistant.Skills.Context.t()) ::
    {:ok, Assistant.Skills.Result.t()} | {:error, term()}
end
```

### 5.6 Validation Helper

A shared module for common flag validation patterns, so handlers don't duplicate logic:

```elixir
defmodule Assistant.Skills.FlagValidator do
  @doc """
  Validate that required flags are present.
  Returns :ok or {:error, {:missing_flags, [flag_names]}}.
  """
  def require(flags, required_names) do
    missing = Enum.reject(required_names, &Map.has_key?(flags, &1))
    if missing == [], do: :ok, else: {:error, {:missing_flags, missing}}
  end

  @doc """
  Validate a flag value is one of the allowed options.
  """
  def validate_enum(flags, flag_name, allowed) do
    case Map.get(flags, flag_name) do
      nil -> :ok  # not present, skip
      value when is_list(value) ->
        invalid = Enum.reject(value, &(&1 in allowed))
        if invalid == [], do: :ok, else: {:error, {:invalid_values, flag_name, invalid, allowed}}
      value ->
        if value in allowed, do: :ok, else: {:error, {:invalid_value, flag_name, value, allowed}}
    end
  end

  @doc """
  Cast a flag value to the expected type.
  """
  def cast_integer(flags, flag_name) do
    case Map.get(flags, flag_name) do
      nil -> {:ok, flags}
      value when is_binary(value) ->
        case Integer.parse(value) do
          {int, ""} -> {:ok, Map.put(flags, flag_name, int)}
          _ -> {:error, {:invalid_type, flag_name, "integer"}}
        end
      value when is_integer(value) -> {:ok, flags}
    end
  end

  def cast_date(flags, flag_name) do
    case Map.get(flags, flag_name) do
      nil -> {:ok, flags}
      value when is_binary(value) ->
        case Date.from_iso8601(value) do
          {:ok, date} -> {:ok, Map.put(flags, flag_name, date)}
          {:error, _} -> {:error, {:invalid_type, flag_name, "date (YYYY-MM-DD)"}}
        end
    end
  end

  def apply_defaults(flags, defaults) do
    Map.merge(defaults, flags)
  end
end
```

### 5.7 Example Handler Using Validation Helper

```elixir
defmodule Assistant.Skills.Tasks.Search do
  @behaviour Assistant.Skills.Handler

  @defaults %{
    "status" => ["todo", "in_progress", "blocked"],
    "sort" => "due_date",
    "limit" => 20
  }

  @valid_statuses ~w(todo in_progress blocked done cancelled)
  @valid_priorities ~w(critical high medium low)
  @valid_sorts ~w(due_date priority created_at updated_at)

  @impl true
  def execute(flags, context) do
    flags = FlagValidator.apply_defaults(flags, @defaults)

    with :ok <- FlagValidator.validate_enum(flags, "status", @valid_statuses),
         :ok <- FlagValidator.validate_enum(flags, "priority", @valid_priorities),
         :ok <- FlagValidator.validate_enum(flags, "sort", @valid_sorts),
         {:ok, flags} <- FlagValidator.cast_integer(flags, "limit"),
         {:ok, flags} <- FlagValidator.cast_date(flags, "due-before"),
         {:ok, flags} <- FlagValidator.cast_date(flags, "due-after") do
      # Build and execute query
      results = build_query(flags, context.user_id) |> Repo.all()
      format_results(results)
    end
  end
end
```

---

## 6. Help Text Generation

### 6.1 Three-Tier Help via SKILL.md + Skill Files

Help text is served from markdown files at three levels, matching the progressive disclosure pattern (Section 3.3):

| Request | Resolves To | Returns |
|---------|-------------|---------|
| `get_skill` | All `SKILL.md` files | Domain summaries (name + description) |
| `get_skill: email` | `email/SKILL.md` | Full domain index (available skills, patterns, notes) |
| `get_skill: email.send` | `email/send.md` | Full skill markdown body (usage, flags, behavior, examples) |
| `get_skill: email.all` | All `email/*.md` | Concatenated content of every skill in the domain |

### 6.2 Help Generator Module

```elixir
defmodule Assistant.CLI.Help do
  @doc """
  Level 1: List all domain summaries from SKILL.md files.
  """
  def generate_top_level do
    domains = Registry.list_domain_indexes()

    lines = Enum.map(domains, fn domain_index ->
      "  #{String.pad_trailing(domain_index.domain, 12)} #{domain_index.description}"
    end)

    """
    Available skill domains:

    #{Enum.join(lines, "\n")}

    Use: get_skill: <domain> for domain details
    Use: get_skill: <domain>.<command> for specific skill details
    Use: get_skill: <domain>.all to load all skills in a domain
    """
  end

  @doc """
  Level 2: Return the SKILL.md content for a domain.
  """
  def generate_domain_help(domain) do
    case Registry.get_domain_index(domain) do
      {:ok, domain_index} -> domain_index.body
      {:error, :not_found} -> "Unknown domain: #{domain}"
    end
  end

  @doc """
  Level 3: Return the skill markdown body as help text.
  """
  def generate_skill_help(skill_def) do
    skill_def.body
  end

  @doc """
  Level 3b: Concatenate all skill bodies in a domain.
  Returns every skill's markdown body joined with separators.
  Excludes SKILL.md (that's the index, not a skill).
  """
  def generate_domain_all(domain) do
    case Registry.list_by_domain(domain) do
      [] ->
        "Unknown domain or no skills: #{domain}"

      skills ->
        skills
        |> Enum.sort_by(& &1.name)
        |> Enum.map_join("\n\n---\n\n", fn skill ->
          "# #{skill.name}\n\n#{skill.body}"
        end)
    end
  end
end
```

### 6.3 Help Command Interception (Dot Notation)

The router intercepts `get_skill` and parses dot notation to resolve the correct tier:

```elixir
defmodule Assistant.Skills.Router do
  def route(command_string) do
    case tokenize(command_string) do
      # get_skill with dot notation argument
      {:ok, ["get_skill:", dot_path]} ->
        resolve_dot_path(dot_path)
      {:ok, ["get_skill"]} ->
        {:help, Help.generate_top_level()}

      # Skill-specific help via --help flag
      {:ok, [skill_name, "--help"]} ->
        case Registry.lookup(skill_name) do
          {:ok, skill_def} -> {:help, Help.generate_skill_help(skill_def)}
          {:error, :not_found} -> {:error, {:unknown_skill, skill_name}}
        end

      {:ok, tokens} ->
        route_command(tokens)
    end
  end

  @doc """
  Resolve dot notation to folder/file path.

  - "email"       -> email/SKILL.md       (Level 2: domain index)
  - "email.send"  -> email/send.md        (Level 3: specific skill)
  - "email.all"   -> all email/*.md files  (Level 3b: full domain context)
  """
  defp resolve_dot_path(dot_path) do
    case String.split(dot_path, ".", parts: 2) do
      [domain] ->
        {:help, Help.generate_domain_help(domain)}

      [domain, "all"] ->
        # ".all" suffix = concatenate every skill in the domain
        {:help, Help.generate_domain_all(domain)}

      [_domain, _command] ->
        # Two segments = domain.command -> direct registry lookup
        case Registry.lookup(dot_path) do
          {:ok, skill_def} -> {:help, Help.generate_skill_help(skill_def)}
          {:error, :not_found} -> {:error, {:unknown_skill, dot_path}}
        end
    end
  end
end
```

**Dot notation resolution**:

| Input | Split | Resolves To |
|-------|-------|-------------|
| `get_skill` | (no arg) | All SKILL.md summaries |
| `get_skill: email` | `["email"]` | `email/SKILL.md` |
| `get_skill: email.send` | `["email", "send"]` | `email/send.md` via Registry key `"email.send"` |
| `get_skill: email.all` | `["email", "all"]` | All `email/*.md` concatenated (full domain context) |
| `get_skill: tasks.create` | `["tasks", "create"]` | `tasks/create.md` via Registry key `"tasks.create"` |

Because skill names use dot notation (e.g., `email.send`), the `resolve_dot_path/1` function performs a direct registry lookup for two-segment paths. The dot notation in `get_skill` and in skill invocation are the same addressing scheme — `email.send` is both how you invoke it and how you look it up.

---

## 7. Skill Registry

### 7.1 File-Based Discovery

Skills and domain indexes (`SKILL.md`) are discovered from the directory tree at startup and watched for changes:

```elixir
defmodule Assistant.Skills.Registry do
  use GenServer

  @skills_dir Application.compile_env(:assistant, :skills_dir, "priv/skills")

  def init(_) do
    {skills, domain_indexes} = load_all(@skills_dir)
    table = :ets.new(:skill_registry, [:set, :named_table, read_concurrency: true])

    # Register individual skills by name
    for skill <- skills do
      :ets.insert(table, {skill.name, skill})
    end

    # Register domain index files (SKILL.md)
    for index <- domain_indexes do
      :ets.insert(table, {{:domain_index, index.domain}, index})
    end

    # Build skill-by-domain grouping
    skill_by_domain = Enum.group_by(skills, & &1.domain)
    :ets.insert(table, {:skill_by_domain, skill_by_domain})

    # Build domain index list for top-level help
    :ets.insert(table, {:domain_indexes, domain_indexes})

    # Build name list for fast existence checks
    names = Enum.map(skills, & &1.name)
    :ets.insert(table, {:all_names, names})

    # Watch for file changes
    {:ok, _watcher} = FileSystem.subscribe(@skills_dir)

    {:ok, %{table: table, skills_dir: @skills_dir}}
  end

  def lookup(name) do
    case :ets.lookup(:skill_registry, name) do
      [{^name, skill}] -> {:ok, skill}
      [] -> {:error, :not_found}
    end
  end

  def skill_exists?(name) do
    case :ets.lookup(:skill_registry, :all_names) do
      [{:all_names, names}] -> name in names
      [] -> false
    end
  end

  @doc "Get domain index (SKILL.md) by domain name"
  def get_domain_index(domain) do
    case :ets.lookup(:skill_registry, {:domain_index, domain}) do
      [{{:domain_index, ^domain}, index}] -> {:ok, index}
      [] -> {:error, :not_found}
    end
  end

  @doc "List all domain indexes for top-level help"
  def list_domain_indexes do
    case :ets.lookup(:skill_registry, :domain_indexes) do
      [{:domain_indexes, indexes}] -> Enum.sort_by(indexes, & &1.domain)
      [] -> []
    end
  end

  def list_by_domain(domain) do
    case :ets.lookup(:skill_registry, :skill_by_domain) do
      [{:skill_by_domain, index}] -> Map.get(index, domain, [])
      [] -> []
    end
  end

  def list_all do
    case :ets.lookup(:skill_registry, :skill_by_domain) do
      [{:skill_by_domain, index}] -> index |> Map.values() |> List.flatten()
      [] -> []
    end
  end

end
```

### 7.2 File Loading (Skills + Domain Indexes)

```elixir
defp load_all(dir) do
  all_files = Path.wildcard(Path.join(dir, "**/*.md"))

  # Separate SKILL.md (domain indexes) from skill files
  {index_files, skill_files} = Enum.split_with(all_files, fn path ->
    Path.basename(path) == "SKILL.md"
  end)

  skills = skill_files
    |> Enum.map(fn path -> load_skill_file(path, dir) end)
    |> Enum.reject(&is_nil/1)

  domain_indexes = index_files
    |> Enum.map(fn path -> load_domain_index(path, dir) end)
    |> Enum.reject(&is_nil/1)

  {skills, domain_indexes}
end

defp load_skill_file(path, skills_root) do
  content = File.read!(path)
  case parse_frontmatter(content) do
    {:ok, frontmatter, body} ->
      %SkillDefinition{
        name: frontmatter["name"],
        description: frontmatter["description"],
        domain: derive_domain(path, skills_root),
        handler: resolve_handler(frontmatter["handler"]),
        schedule: frontmatter["schedule"],
        tags: frontmatter["tags"] || [],
        author: frontmatter["author"],
        body: body,
        path: path
      }
    {:error, reason} ->
      Logger.warning("Failed to parse skill file #{path}: #{inspect(reason)}")
      nil
  end
end

defp load_domain_index(path, skills_root) do
  content = File.read!(path)
  case parse_frontmatter(content) do
    {:ok, frontmatter, body} ->
      %DomainIndex{
        domain: frontmatter["domain"] || derive_domain(path, skills_root),
        description: frontmatter["description"],
        body: body,
        path: path
      }
    {:error, reason} ->
      Logger.warning("Failed to parse domain index #{path}: #{inspect(reason)}")
      nil
  end
end
```

### 7.3 SkillDefinition and DomainIndex Structs

```elixir
defmodule Assistant.Skills.SkillDefinition do
  @type t :: %__MODULE__{
    name: String.t(),
    description: String.t(),
    domain: String.t(),
    handler: module() | nil,
    schedule: String.t() | nil,
    tags: [String.t()],
    author: String.t() | nil,
    body: String.t(),
    path: String.t()
  }

  defstruct [:name, :description, :domain, :handler, :schedule,
             :author, :body, :path, tags: []]
end

defmodule Assistant.Skills.DomainIndex do
  @moduledoc "Represents a SKILL.md domain index file."
  @type t :: %__MODULE__{
    domain: String.t(),
    description: String.t(),
    body: String.t(),
    path: String.t()
  }

  defstruct [:domain, :description, :body, :path]
end
```

### 7.4 Hot-Reload via FileSystem Watcher

```elixir
def handle_info({:file_event, _watcher, {path, events}}, state) do
  if String.ends_with?(path, ".md") do
    cond do
      :removed in events ->
        remove_skill(path, state)
      :created in events or :modified in events ->
        reload_skill(path, state)
      true ->
        :ok
    end
  end
  {:noreply, state}
end

defp reload_skill(path, state) do
  case load_skill_file(path, state.skills_dir) do
    nil -> :ok
    skill ->
      case validate_skill(skill) do
        :ok ->
          :ets.insert(state.table, {skill.name, skill})
          rebuild_indexes(state)
          Logger.info("Reloaded skill: #{skill.name} from #{path}")
        {:error, reason} ->
          Logger.warning("Invalid skill file #{path}: #{inspect(reason)}")
      end
  end
end
```

---

## 8. Markdown Content Search (PostgreSQL FTS)

### 8.1 The Problem

Google Drive API cannot search inside markdown file contents. Users need to search their Obsidian vault by content ("find notes about Q1 strategy"). The assistant must be able to grep markdown contents.

### 8.2 Solution: Index in PostgreSQL

When markdown files are created or updated via Drive, their content is indexed in PostgreSQL FTS:

```sql
CREATE TABLE markdown_index (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  drive_file_id VARCHAR(255) NOT NULL UNIQUE,
  drive_file_name VARCHAR(500) NOT NULL,
  drive_folder_id VARCHAR(255),
  drive_folder_path TEXT,
  content TEXT NOT NULL,
  frontmatter JSONB DEFAULT '{}',
  word_count INTEGER,
  search_vector tsvector GENERATED ALWAYS AS (
    setweight(to_tsvector('english', coalesce(drive_file_name, '')), 'A') ||
    setweight(to_tsvector('english', coalesce(frontmatter->>'title', '')), 'A') ||
    setweight(to_tsvector('english', coalesce(content, '')), 'B')
  ) STORED,
  tags TEXT[] DEFAULT '{}',
  last_indexed_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_markdown_search ON markdown_index USING gin(search_vector);
CREATE INDEX idx_markdown_drive_file ON markdown_index(drive_file_id);
CREATE INDEX idx_markdown_folder ON markdown_index(drive_folder_id);
CREATE INDEX idx_markdown_tags ON markdown_index USING gin(tags);
CREATE INDEX idx_markdown_frontmatter ON markdown_index USING gin(frontmatter);
```

### 8.3 Indexing Pipeline

```
Markdown file created/updated on Drive
    |
    v
Drive webhook or periodic sync (Oban job)
    |
    v
Download file content from Drive API
    |
    v
Parse frontmatter (extract YAML, tags, title)
    |
    v
Upsert into markdown_index table
    |
    v
tsvector auto-generated by PostgreSQL
```

```elixir
defmodule Assistant.Markdown.Indexer do
  def index_file(drive_file_id) do
    with {:ok, metadata} <- Drive.get_file_metadata(drive_file_id),
         {:ok, content} <- Drive.download_file_content(drive_file_id),
         {:ok, frontmatter, _body} <- parse_frontmatter(content) do

      %MarkdownIndex{}
      |> Ecto.Changeset.change(%{
        drive_file_id: drive_file_id,
        drive_file_name: metadata.name,
        drive_folder_id: metadata.parents |> List.first(),
        content: content,
        frontmatter: frontmatter,
        word_count: content |> String.split(~r/\s+/) |> length(),
        tags: frontmatter["tags"] || [],
        last_indexed_at: DateTime.utc_now()
      })
      |> Repo.insert(
        on_conflict: {:replace, [:content, :frontmatter, :word_count, :tags, :drive_file_name, :last_indexed_at, :updated_at]},
        conflict_target: :drive_file_id
      )
    end
  end
end
```

---

## 9. Workflow Builder (Composing Skills)

### 9.1 Concept

Skills are static tools — they don't change. What the assistant creates are **workflows**: compositions of existing skills for repeatable tasks. A meta-skill (`workflow.build`) guides the creation process. Workflows are markdown files whose Behavior section references other skills.

### 9.2 Workflow Builder (`workflow/build.md`)

```markdown
---
name: workflow.build
description: Create a new workflow from a description
handler: Assistant.Skills.Workflow.Build
---

# workflow.build

Create a new workflow by composing existing skills into a repeatable markdown definition.

## Usage

workflow.build --name <name> --description <text> [--domain <domain>] [--steps <text>] [--schedule <cron>]

## Flags

--name          Action name for the new skill, e.g. "weekly_report" (required)
--description   What the skill does (required)
--domain        Target domain folder (default: custom)
--steps         Description of the steps the skill performs
--schedule      Cron expression if the skill should run on a schedule

## Behavior

1. Validate the skill name (lowercase, alphanumeric + underscore, no conflicts)
2. Derive full dot-notation name: {domain}.{name} (e.g., workflows.weekly_report)
3. Generate a markdown file with minimal YAML frontmatter and a Behavior section
4. Write the file to skills/{domain}/{name}.md
5. The registry auto-discovers it via file watcher
6. Return confirmation with the skill name and path

## Examples

workflow.build --name weekly_report --description "Generate and send weekly project status report" --schedule "0 9 * * 1"
workflow.build --name client_onboard --description "Run the new client onboarding checklist" --steps "Create tasks, send welcome email, set up HubSpot contact"
workflow.build --name expense_report --domain finance --description "Generate monthly expense report"
```

### 9.3 Workflow Builder Handler

```elixir
defmodule Assistant.Skills.Workflow.Build do
  @behaviour Assistant.Skills.Handler
  @skills_dir "priv/skills"

  @impl true
  def execute(flags, _context) do
    domain = flags["domain"] || "workflows"
    with :ok <- FlagValidator.require(flags, ["name", "description"]),
         :ok <- validate_name(flags["name"]),
         full_name = "#{domain}.#{flags["name"]}",
         :ok <- validate_no_conflict(full_name) do

      content = generate_skill_file(full_name, flags)
      path = Path.join([@skills_dir, domain, "#{flags["name"]}.md"])

      File.mkdir_p!(Path.dirname(path))
      File.write!(path, content)

      {:ok, %SkillResult{
        status: :ok,
        content: "Created skill '#{full_name}' at #{path}. It is now available.",
        side_effects: [:skill_created],
        metadata: %{skill_path: path, skill_name: full_name}
      }}
    end
  end

  defp generate_skill_file(full_name, flags) do
    schedule_line = if flags["schedule"], do: "\nschedule: \"#{flags["schedule"]}\"", else: ""

    """
    ---
    name: #{full_name}
    description: #{flags["description"]}#{schedule_line}
    author: assistant
    created: #{Date.utc_today()}
    ---

    # #{full_name}

    #{flags["description"]}

    ## Usage

    #{full_name}

    ## Behavior

    #{flags["steps"] || "Execute the skill as described above."}

    ## Examples

    #{full_name}
    """
  end

  @reserved_names ~w(all help)

  defp validate_name(name) do
    cond do
      name in @reserved_names ->
        {:error, "Name '#{name}' is reserved (used by get_skill routing)"}
      not Regex.match?(~r/^[a-z][a-z0-9_]*$/, name) ->
        {:error, "Skill name must be lowercase alphanumeric + underscore, starting with a letter"}
      true ->
        :ok
    end
  end

  defp validate_no_conflict(name) do
    if Registry.skill_exists?(name) do
      {:error, "Skill '#{name}' already exists. Choose a different name."}
    else
      :ok
    end
  end
end
```

### 9.4 Skill Validation

```elixir
defmodule Assistant.Skills.Validator do
  def validate_skill(skill_def) do
    with :ok <- validate_name_present(skill_def),
         :ok <- validate_description_present(skill_def),
         :ok <- validate_name_format(skill_def.name),
         :ok <- validate_body_present(skill_def) do
      :ok
    end
  end

  defp validate_name_present(%{name: nil}), do: {:error, :missing_name}
  defp validate_name_present(%{name: ""}), do: {:error, :missing_name}
  defp validate_name_present(_), do: :ok

  defp validate_description_present(%{description: nil}), do: {:error, :missing_description}
  defp validate_description_present(%{description: ""}), do: {:error, :missing_description}
  defp validate_description_present(_), do: :ok

  @reserved_commands ~w(all help)

  defp validate_name_format(name) do
    # Dot notation: domain.action (e.g., email.send, workflows.daily_digest)
    # "all" and "help" are reserved suffixes used by get_skill routing
    case String.split(name, ".", parts: 2) do
      [_domain, command] when command in @reserved_commands ->
        {:error, {:reserved_name, name, "'#{command}' is reserved by get_skill routing"}}

      [_domain, _command] ->
        if Regex.match?(~r/^[a-z][a-z0-9_]*\.[a-z][a-z0-9_]*$/, name) do
          :ok
        else
          {:error, {:invalid_name, name, "expected format: domain.action"}}
        end

      _ ->
        {:error, {:invalid_name, name, "expected format: domain.action"}}
    end
  end

  defp validate_body_present(%{body: nil}), do: {:error, :missing_body}
  defp validate_body_present(%{body: ""}), do: {:error, :missing_body}
  defp validate_body_present(_), do: :ok
end
```

---

## 10. Orchestrator System Prompt

### 10.1 CLI-First Prompt

```
You are an AI assistant. You help users by executing skills.

To perform actions, output commands inside ```cmd code blocks:

```cmd
email.send --to bob@co.com --subject "Hello" --body "Hi Bob!"
```

To explore available skills:
```cmd
get_skill
```

To see skills in a specific domain:
```cmd
get_skill: email
```

To see details about a specific skill:
```cmd
get_skill: email.send
```

To load all skills in a domain at once:
```cmd
get_skill: email.all
```

Rules:
- Each command goes on its own line inside a ```cmd block
- Arguments with spaces must be quoted: --subject "Q1 Report"
- Flags with multiple values are space-separated: --to alice@co.com bob@co.com
- Boolean flags are true by presence: --overdue
- You can output multiple commands to accomplish multi-step tasks
- Text outside ```cmd blocks is your response to the user

{available_skills_summary}

{user_context}
{task_summary}
{memory_context}
```

### 10.2 Available Skills in Prompt

The system prompt includes domain summaries (from SKILL.md files) for quick orientation. The LLM can drill into any domain for full details:

```
Available skill domains:

  email        Email tools for Gmail integration
  tasks        Task management and tracking
  calendar     Google Calendar event management
  drive        Google Drive file management
  hubspot      HubSpot CRM integration
  memory       Long-term memory storage and search
  markdown     Markdown file editing and search
  skill        Skill/workflow management (build, list)

Use: get_skill: <domain> for domain details
Use: get_skill: <domain>.<command> for specific skill details
Use: get_skill: <domain>.all to load all skills in a domain

Quick reference (common skills):
  email.send --to ADDR --subject "..." --body "..."
  tasks.search --query "..." [--status overdue] [--priority high]
  tasks.create --title "..." [--priority high] [--due DATE]
  memory.save --content "..." [--category preference]
  memory.search --query "..."
```

This two-part prompt gives the LLM both the broad domain map (from SKILL.md descriptions) and quick-reference shortcuts for the most common skills. The LLM uses `get_skill: <domain>` to drill into a domain's SKILL.md when it needs to discover available skills, `get_skill: <domain>.<command>` for flag-level details, and `get_skill: <domain>.all` to load every skill in a domain at once. Dot notation maps directly to the folder/file structure: `email.send` resolves to `skills/email/send.md`.

---

## 11. Integration with Sub-Agent Orchestration

### 11.1 How Sub-Agents Use CLI Commands

In multi-agent mode, sub-agents also output CLI commands. Their scoped context includes only the skills relevant to their mission:

**Sub-agent system prompt**:

```
You are a focused execution agent. Complete your mission using the available skills.

Output commands inside ```cmd blocks. Return a summary when done.

Available skills:
  tasks.search   Search and filter tasks
  email.send     Send an email

Use: get_skill: <domain>.<command> for skill details
```

### 11.2 Dispatch Changes

The `dispatch_agent` tool passes skill names using dot notation:

```
dispatch_agent(
  agent_id: "report_sender",
  mission: "Search for overdue tasks, compile into a report, and email to Bob.",
  skills: ["tasks.search", "email.send"],
  context: "Bob's email is bob@company.com"
)
```

### 11.3 Compatibility Layer

The router output (`RoutedCommand`) feeds into the same `Executor` module. The change is in how commands enter the system (CLI text parsing), not how they execute:

```
CLI command:                    Previous JSON tool call:
  tasks.search --status overdue   use_skill(skill: "tasks.search",
       |                            arguments: {status: ["overdue"]})
       v                                |
  CLI Router                            v
       |                          MetaTools.UseSkill
       v                                |
  RoutedCommand{                        v
    skill_name: "tasks.search",   Registry.get_by_name
    handler: Skills.Tasks.Search        |
    flags: %{"status" => "overdue"}     v
  }                               Skills.Tasks.Search.execute
       |
       v
  Skills.Tasks.Search.execute
       |
       v
  SkillResult                     SkillResult
```

Handler modules, executor, circuit breakers, and skill results are unchanged. Only the input path changes.

---

## 12. Scheduled Skills

### 12.1 Cron Integration

Skills with a `schedule` field in their YAML frontmatter are registered with Quantum:

```elixir
defmodule Assistant.Scheduler.SkillScheduler do
  def register_scheduled_skills do
    Registry.list_all()
    |> Enum.filter(& &1.schedule)
    |> Enum.each(fn skill ->
      Quantum.add_job(Assistant.Scheduler.Cron, skill_job_name(skill), %Quantum.Job{
        schedule: Crontab.CronExpression.Parser.parse!(skill.schedule),
        task: {__MODULE__, :execute_scheduled_skill, [skill.name]}
      })
    end)
  end

  def execute_scheduled_skill(skill_name) do
    %{skill_name: skill_name}
    |> Assistant.Workers.ScheduledSkillWorker.new()
    |> Oban.insert()
  end
end
```

### 12.2 Workflow Scheduling

When a workflow with a `schedule` field is created via `workflow.build`, it is automatically registered with Quantum via the hot-reload watcher. When the schedule fires, the system creates a synthetic conversation and runs the workflow through the normal orchestration pipeline.

---

## 13. Module Structure

### 13.1 New Modules

| Module | Type | Purpose |
|--------|------|---------|
| `Assistant.CLI.Extractor` | Parser | Extract ` ```cmd ` blocks from LLM output |
| `Assistant.CLI.Help` | Generator | Generate help text from skill markdown |
| `Assistant.Skills.Router` | Router | Tokenize + route commands to handlers |
| `Assistant.Skills.SkillDefinition` | Struct | Parsed skill file representation |
| `Assistant.Skills.DomainIndex` | Struct | Parsed SKILL.md domain index representation |
| `Assistant.Skills.FlagValidator` | Helper | Common flag validation utilities |
| `Assistant.Skills.Validator` | Validator | Validate skill markdown files |
| `Assistant.Skills.Workflow.Build` | Handler | Create new workflows (compositions of skills) |
| `Assistant.Markdown.Indexer` | Service | Index markdown content in PostgreSQL FTS |
| `Assistant.Markdown.MarkdownIndex` | Schema | Ecto schema for markdown content index |
| `Assistant.Workers.MarkdownIndexWorker` | Oban Worker | Async markdown indexing |
| `Assistant.Scheduler.SkillScheduler` | Scheduler | Register scheduled skills with Quantum |
| `Assistant.Workers.ScheduledSkillWorker` | Oban Worker | Execute scheduled skills |

### 13.2 Modified Modules

| Module | Change |
|--------|--------|
| `Assistant.Skills.Registry` | File-based discovery (markdown files) + hot-reload. ETS keyed by skill name. |
| `Assistant.Skills.Executor` | Routes via `RoutedCommand` instead of `use_skill`. Handlers receive flags map. |
| `Assistant.Orchestrator.Engine` | Processes LLM text output for ` ```cmd ` blocks instead of tool calls. |
| `Assistant.Orchestrator.Context` | System prompt includes skill listings instead of tool definitions. |
| `Assistant.Orchestrator.SubAgent` | Sub-agent context uses skill listings instead of scoped `use_skill`. |

### 13.3 Handler Behaviour (Simplified)

```elixir
defmodule Assistant.Skills.Handler do
  @callback execute(flags :: map(), context :: Assistant.Skills.Context.t()) ::
    {:ok, Assistant.Skills.Result.t()} | {:error, term()}
end
```

Single callback. All metadata (domain, description, usage) lives in the markdown file.

### 13.4 File Layout

```
lib/assistant/
  +-- cli/
  |   +-- extractor.ex           # Extract ```cmd blocks from LLM output
  |   +-- help.ex                # Generate help text from skill markdown
  |
  +-- skills/
  |   +-- router.ex              # Tokenize + route commands (NEW)
  |   +-- registry.ex            # File-based skill discovery (MODIFIED)
  |   +-- skill_definition.ex    # SkillDefinition struct (NEW)
  |   +-- domain_index.ex        # DomainIndex struct for SKILL.md (NEW)
  |   +-- handler.ex             # Simplified handler behaviour (NEW)
  |   +-- flag_validator.ex      # Common flag validation helpers (NEW)
  |   +-- validator.ex           # Skill file validation (NEW)
  |   +-- executor.ex            # Routes RoutedCommand to handlers (MODIFIED)
  |   +-- result.ex              # SkillResult (unchanged)
  |   +-- context.ex             # SkillContext (unchanged)
  |   +-- handlers/              # Built-in skill handlers
  |   |   +-- email/
  |   |   |   +-- send.ex        # email.send handler
  |   |   |   +-- search.ex      # email.search handler
  |   |   |   +-- read.ex        # email.read handler
  |   |   |   +-- draft.ex       # email.draft handler
  |   |   +-- tasks/
  |   |   |   +-- create.ex
  |   |   |   +-- search.ex
  |   |   |   +-- get.ex
  |   |   |   +-- update.ex
  |   |   |   +-- delete.ex
  |   |   +-- calendar/
  |   |   +-- drive/
  |   |   +-- hubspot/
  |   |   +-- memory/
  |   |   +-- markdown/
  |   |   +-- workflow/
  |   |       +-- build.ex
  |
  +-- markdown/
  |   +-- indexer.ex             # Content indexing (NEW)
  |   +-- markdown_index.ex      # Ecto schema (NEW)
  |
  +-- workers/
      +-- markdown_index_worker.ex    # Async indexing (NEW)
      +-- scheduled_skill_worker.ex   # Scheduled skill execution (NEW)

priv/skills/                     # Skill definition files (one per action)
  +-- email/
  |   +-- SKILL.md               # Domain index (progressive disclosure)
  |   +-- send.md                # email.send
  |   +-- search.md              # email.search
  |   +-- read.md                # email.read
  |   +-- draft.md               # email.draft
  +-- tasks/
  |   +-- SKILL.md               # Domain index
  |   +-- create.md              # tasks.create
  |   +-- search.md              # tasks.search
  |   +-- get.md                 # tasks.get
  |   +-- update.md              # tasks.update
  |   +-- delete.md              # tasks.delete
  +-- calendar/
  |   +-- SKILL.md               # Domain index
  |   +-- create.md              # calendar.create
  |   +-- list.md                # calendar.list
  |   +-- update.md              # calendar.update
  +-- drive/
  |   +-- SKILL.md
  +-- hubspot/
  |   +-- SKILL.md
  +-- memory/
  |   +-- SKILL.md
  +-- markdown/
  |   +-- SKILL.md
  +-- workflow/
  |   +-- SKILL.md
  |   +-- build.md               # workflow.build
  +-- workflows/                 # User/assistant-created workflows
  |   +-- SKILL.md               # Auto-generated when workflows added
```

---

## 14. Testing Strategy

### 14.1 Unit Tests

**CLI.Extractor**:
- Extracts single ` ```cmd ` block from LLM output
- Extracts multiple ` ```cmd ` blocks
- Separates conversational text from commands
- Handles empty output (no commands)
- Handles output with only text (no commands)

**Skills.Router**:
- Tokenizes simple commands correctly
- Handles quoted strings ("value with spaces")
- Matches skill name to registered skill
- Returns error for unknown skill names
- Parses flags as key-value pairs (best-effort)
- Handles boolean flags (presence = true)
- Handles multi-value flags

**CLI.Help**:
- Generates correct top-level domain listing
- Generates skill-level help from markdown body
- Intercepts `--help` commands correctly

**Skills.Registry (file-based)**:
- Discovers all skill files in directory tree
- Parses minimal YAML frontmatter correctly
- Derives domain from directory path
- Builds ETS lookup by skill name
- Handles hot-reload on file create/modify/delete
- Validates skill files on load
- Rejects invalid files (missing name, missing description)

**Skills.FlagValidator**:
- Detects missing required flags
- Validates enum values
- Casts integer and date types
- Applies defaults correctly

**Skills.Workflow.Build**:
- Generates valid markdown with minimal YAML frontmatter
- Rejects conflicting skill names
- Rejects invalid skill name formats
- Created skills are discoverable by registry

### 14.2 Integration Tests

- Full flow: LLM output with ` ```cmd ` block -> extractor -> router -> handler -> result
- Multi-command: LLM outputs 3 commands -> all execute in order -> all results returned
- Help request: `tasks.search --help` -> returns markdown body, not execution
- Custom skill creation: `workflow.build --name test_skill ...` -> file created -> registry hot-reloads
- Markdown search: file indexed -> `markdown.search --query "..."` -> returns matches
- Scheduled skill: skill with `schedule` -> Quantum registers job -> fires on time
- Handler validation: missing required flag -> handler returns clear error message

### 14.3 Behavioral Tests

- LLM produces well-formed CLI commands for various user requests
- LLM uses `--help` to discover flag details before unfamiliar commands
- LLM chains multiple commands for multi-step requests
- LLM handles command errors and retries with corrected flags

---

## 15. Open Questions

1. **Pipe syntax**: Should the system support piping command results? e.g., `tasks.search --overdue | email.send --to bob --subject "Report" --body {stdin}`. Natural but adds parser complexity. Recommend: defer — the LLM handles multi-step sequencing via separate commands.

2. **Approach B reconsidered**: Should flag definitions be extracted from the `## Flags` section of markdown for centralized validation in Phase 2? This would be additive — handlers still validate, but the router could pre-validate common patterns. Recommend: defer unless handler validation proves error-prone.

3. **Workflow marketplace**: Should workflows be shareable between users/instances? Natural extension of the markdown-based approach. Defer to Phase 2.

4. **Template language**: Should workflow templates use a formal template language (EEx, Mustache) or rely on the LLM to interpret the Behavior section? Current design: LLM interpretation. A formal template language would be more deterministic but less flexible.

5. **Command aliases**: Should frequently-used commands have short aliases? e.g., `st` for `tasks.search`. Could reduce token usage. Recommend: defer — full names are clearer for the LLM.

6. **~~Skill builder vs workflow builder~~** (**RESOLVED — fully applied**): The "skill builder" is a **workflow builder**. Skills are static tools that don't change. What the assistant creates are **workflows** — compositions of existing skills for repeatable tasks (daily digest, weekly report). Renamed throughout: `workflow.build`, `workflows/` directory, section 9 describes workflow creation.

7. **Orchestrator direct skill access** (**RESOLVED**): The orchestrator can directly invoke **read-only skills** (`*.search`, `*.get`, `*.list`, `*.read`) for quick lookups without spinning up a sub-agent. Only **mutating skills** (`*.create`, `*.update`, `*.delete`, `*.send`) require delegation to sub-agents. This gives the orchestrator speed for information gathering while maintaining the delegation pattern for actions with side effects.

---

## 16. Design Decision Summary

| Decision | Choice | Rationale |
|----------|--------|-----------|
| YAML frontmatter | Minimal: `name` + `description` only | Machines need routing info; everything else is human/LLM-readable markdown |
| Markdown body | Full skill definition (man-page style) | Self-documenting; served directly as help text; source of truth |
| Granularity | One file per action (SRP) | Atomic, composable, testable, replaceable skills |
| Directory structure | Domain grouping (`email/`, `tasks/`, etc.) | Domain derived from path, not YAML field |
| Flag validation | Handler-side (Approach A) | Keeps system simple; markdown is for humans, not machine parsing |
| Flag validation helpers | Shared `FlagValidator` module | Common patterns without duplication across handlers |
| LLM interface | CLI commands in ` ```cmd ` fenced blocks | LLMs produce CLI commands reliably; natural discovery via `--help` |
| Discovery | Progressive disclosure via dot notation (4 levels) | `get_skill` -> summaries, `get_skill: email` -> SKILL.md, `get_skill: email.send` -> skill, `get_skill: email.all` -> all |
| Dot notation | `domain.command` maps to `skills/{domain}/{command}.md` | Uniform, predictable addressing; LLM-friendly; mirrors file structure |
| `.all` suffix | `get_skill: domain.all` concatenates all skills in domain | Loads full domain context in one call; useful for complex multi-skill tasks |
| Domain index | SKILL.md per domain folder | Bridges domain-level discovery and individual skill help; auto-generated for custom domain |
| Skill registration | File-based with hot-reload (FileSystem watcher) | Runtime skill creation; no recompile needed |
| Custom skills | Template-based (markdown body interpreted by LLM) | Users/assistant can create skills without Elixir code |
| Markdown content search | PostgreSQL FTS index of Drive markdown content | Drive API cannot grep contents; FTS provides ranked search |
| Handler interface | Single `execute(flags, context)` callback | All metadata in markdown; handlers are pure execution |
| Scheduled skills | YAML `schedule` field -> Quantum cron | Declarative; only optional YAML field beyond name/description |
| Skill naming | `domain.command` dot notation | Mirrors file path; unified addressing for invocation and discovery; globally unique by filesystem |
| Orchestrator access | Read-only skills directly; mutating skills via sub-agents | Orchestrator can `*.search`/`*.get`/`*.list`/`*.read` for speed; `*.create`/`*.update`/`*.delete`/`*.send` delegated |
| Custom compositions | Workflows (not "custom skills") | Skills are static tools; workflows compose skills into repeatable tasks (daily digest, weekly report) |
