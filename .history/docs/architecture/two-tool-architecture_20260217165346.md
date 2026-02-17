# Two-Tool Architecture and Agentic Loop: Architectural Design

> Part of the Skills-First AI Assistant architecture.
> Planning only — no implementation.
>
> **IMPORTANT — SUPERSESSION HISTORY**:
>
> 1. **Multi-agent supersession**: The single-loop agentic pattern (Sections 4-5) has been
>    **superseded** by the multi-agent orchestration pattern in `sub-agent-orchestration.md`.
>    The orchestrator no longer calls `use_skill` directly — it delegates to sub-agents.
>
> 2. **CLI-first supersession**: The JSON Schema tool-calling pattern (Sections 2-3, 7, 9) has
>    been **superseded** by the CLI-first skill definition system in `markdown-skill-system.md`.
>    Skills are now markdown files with YAML frontmatter. The LLM outputs CLI command strings
>    in ` ```cmd ` fenced blocks, not JSON tool calls. `get_skill` is replaced by `--help` text
>    generation. `use_skill` is replaced by CLI parsing + execution. The skill registry is now
>    file-based with hot-reload via FileSystem watcher.
>
> **What remains valid in this document**:
> - Section 4-5: Agentic loop structure (single-loop fallback mode)
> - Section 6: Context assembly and token budgets (adapted for CLI prompt)
> - Section 6A: Prompt caching strategy (cache principles apply, payload format changes)
> - Section 10: LLM interaction patterns (behavioral patterns transfer to CLI)
> - Section 11: Message persistence (tool call traces become command execution traces)
> - Section 12: Testing strategy (test categories remain valid, specifics change)
> - Section 14: Integration points (memory, circuit breakers, voice — all still apply)
>
> **For the current design**, see `markdown-skill-system.md` (CLI interface) and
> `sub-agent-orchestration.md` (multi-agent coordination).

## 1. Overview

> **EVOLVED**: This section describes the original two-tool framing. The problem analysis (1.1)
> remains valid. The solution has evolved from JSON meta-tools to CLI commands — see
> `markdown-skill-system.md` for the current approach. The design principles (1.3) carry forward.

### 1.1 The Problem

The current architecture registers every skill as an individual tool definition sent to the LLM on every request. With 20+ skills across email, calendar, drive, HubSpot, tasks, markdown, and memory domains, this creates three compounding problems:

1. **Token bloat**: Every tool definition consumes prompt tokens. 20 tools with JSON schemas can easily consume 3,000-5,000 tokens per request — tokens that could be used for conversation context and memory.

2. **Decision paralysis**: LLMs make worse tool selections when presented with many similar options simultaneously. The LLM must distinguish between `tasks.search`, `email.search`, `drive.search`, and `hubspot.search` on every single turn, even when the user is clearly talking about tasks.

3. **Rigidity**: Adding a new skill requires the LLM to implicitly "learn" about it by seeing it in the tool list. There is no discovery protocol — the skill either exists in the tool list or it does not.

### 1.2 The Solution: Two Meta-Tools → CLI Commands

> **EVOLVED**: The original solution defined two JSON meta-tools (`get_skill`/`use_skill`).
> This has been replaced by a CLI-first interface where:
> - **Discovery** (`get_skill`) → `--help` text output per command/subcommand
> - **Execution** (`use_skill`) → CLI command strings in ` ```cmd ` fenced blocks
> - **Skill definition** (Elixir modules) → Markdown files with YAML frontmatter
>
> The original two-tool pattern is retained as a conceptual ancestor and as the
> `:single_loop` fallback mode. See `markdown-skill-system.md` for the current design.

The original design presented exactly **two** tools:

| Tool | Purpose | CLI Equivalent |
|------|---------|----------------|
| `get_skill` | Discover what skills exist, filtered by domain or capability | `email --help` or `tasks.search --help` |
| `use_skill` | Invoke a specific skill by name with parameters | ` ```cmd\nemail.send --to bob --subject "Q1 Report"\n``` ` |

The LLM operates in a discovery-then-action cycle. In the CLI-first approach:

```
User: "Send an email to Bob about the Q1 report"

LLM thinks: I need to send an email. I know the email command.
LLM outputs:
  ```cmd
  email.send --to bob@co.com --subject "Q1 Report" --body "Here is the Q1 report."
  ```

Engine: Extracts command from ```cmd block -> CLI Parser -> Execute -> Return result

LLM: "Done — I sent the email to Bob about the Q1 report."
```

### 1.3 Why This Works

**Constant tool surface**: The LLM always sees exactly 2 tools (or in CLI mode, a compact command summary in the system prompt) regardless of how many skills exist. Adding 10 new skills changes nothing about the tool definitions the LLM receives.

**Progressive disclosure**: The LLM only sees skill details when it asks for them. A calendar question never loads email schemas. In CLI mode, the LLM can ask `email --help` for domain-level help or `email.send --help` for command-specific flags.

**Better decisions**: When the LLM constructs a CLI command, it has already committed to a specific command and subcommand. Flag validation catches mistakes.

**Natural for LLMs**: LLMs are trained on massive CLI documentation. They produce well-formed CLI commands more reliably than nested JSON structures.

**Self-creating**: In CLI mode, new skills can be created by writing markdown files with YAML frontmatter — no Elixir code needed for the definition.

**Token savings**: Instead of ~4,000 tokens for 20 tool schemas, a compact CLI summary costs ~200-400 tokens. Full command help is loaded on-demand.

---

## 2. Tool Definitions

> **SUPERSEDED**: These JSON Schema tool definitions are replaced by the CLI-first interface.
> - `get_skill` → Replaced by `--help` text generation (see `markdown-skill-system.md` Section 6)
> - `use_skill` → Replaced by CLI command parsing from ` ```cmd ` fenced blocks (see `markdown-skill-system.md` Sections 3-4)
> - JSON Schema validation → Replaced by YAML frontmatter flag validation (see `markdown-skill-system.md` Section 5)
>
> Retained here for the `:single_loop` fallback mode.

### 2.1 get_skill

```elixir
defmodule Assistant.Skills.MetaTools.GetSkill do
  @doc """
  Meta-tool that the LLM calls to discover available skills.
  Returns skill names, descriptions, and parameter schemas.
  """

  def tool_definition do
    %{
      name: "get_skill",
      description: """
      Discover available skills (capabilities). Call this to find out what \
      you can do in a specific domain or to search for a skill by keyword.

      Returns a list of skills with their names, descriptions, and parameter schemas.

      You MUST call get_skill before use_skill if you don't already know \
      the exact skill name and its required parameters.
      """,
      parameters: %{
        "type" => "object",
        "properties" => %{
          "domain" => %{
            "type" => "string",
            "enum" => [],  # Populated dynamically from registry
            "description" => "Filter skills by domain. Available domains are listed in the enum."
          },
          "search" => %{
            "type" => "string",
            "description" => "Search for skills by keyword in name or description. Optional."
          }
        },
        "required" => []
      }
    }
  end
end
```

**Dynamic enum population**: The `domain` enum is populated at startup from the skill registry. If registered domains are `[:email, :calendar, :drive, :tasks, :hubspot, :markdown, :memory]`, the enum becomes `["email", "calendar", "drive", "tasks", "hubspot", "markdown", "memory"]`. This gives the LLM a clear menu of domains without enumerating every skill.

**Return format**:

```json
{
  "domain": "email",
  "skills": [
    {
      "name": "email.send",
      "description": "Send an email to one or more recipients.",
      "parameters": {
        "type": "object",
        "properties": {
          "to": {"type": "array", "items": {"type": "string"}, "description": "Email addresses"},
          "subject": {"type": "string"},
          "body": {"type": "string"},
          "cc": {"type": "array", "items": {"type": "string"}, "description": "CC recipients. Optional."},
          "attachments": {"type": "array", "items": {"type": "string"}, "description": "File IDs to attach. Optional."}
        },
        "required": ["to", "subject", "body"]
      }
    },
    {
      "name": "email.read",
      "description": "Read a specific email by ID.",
      "parameters": { ... }
    },
    {
      "name": "email.search",
      "description": "Search emails by query, sender, date range.",
      "parameters": { ... }
    }
  ]
}
```

The LLM receives the full parameter schema for each skill in the domain. This is the moment of "progressive disclosure" — schemas are loaded only when the LLM asks for them.

### 2.2 use_skill

```elixir
defmodule Assistant.Skills.MetaTools.UseSkill do
  @doc """
  Meta-tool that the LLM calls to execute a discovered skill.
  The skill name must match a registered skill exactly.
  Arguments are validated against the skill's parameter schema before execution.
  """

  def tool_definition do
    %{
      name: "use_skill",
      description: """
      Execute a skill by name with the given arguments. You must know the \
      skill name and its required parameters — call get_skill first if unsure.

      The skill executes and returns its result. If the skill fails, you'll \
      receive an error message explaining what went wrong.
      """,
      parameters: %{
        "type" => "object",
        "properties" => %{
          "skill" => %{
            "type" => "string",
            "description" => "The exact name of the skill to execute (e.g., 'email.send', 'tasks.create')"
          },
          "arguments" => %{
            "type" => "object",
            "description" => "The arguments to pass to the skill, matching its parameter schema"
          }
        },
        "required" => ["skill", "arguments"]
      }
    }
  end
end
```

**Key design point**: The `arguments` field is a free-form object. Validation happens server-side against the skill's registered JSON schema, not in the `use_skill` tool definition itself. This keeps the `use_skill` definition stable and minimal.

---

## 3. Execution Flow

> **SUPERSEDED**: These execution flows describe the JSON meta-tool path. The CLI-first
> equivalent is in `markdown-skill-system.md`:
> - Section 3: CLI Parser (tokenization, command resolution, flag parsing, validation)
> - Section 4: CLI Extractor (` ```cmd ` block detection in LLM output)
> - Section 5: Execution Pipeline (parsed command → handler dispatch → result)
>
> Retained here for the `:single_loop` fallback mode.

### 3.1 get_skill Execution

```
LLM calls: get_skill(domain: "email")
    |
    v
MetaTools.GetSkill.execute/2
    |
    v
Query Skills.Registry for domain :email
    |
    v
For each skill module in domain:
    call skill.tool_definition()
    |
    v
Format as JSON response
    |
    v
Return to LLM as tool result
```

```elixir
defmodule Assistant.Skills.MetaTools.GetSkill do
  def execute(params, _context) do
    skills = cond do
      domain = params["domain"] ->
        Registry.get_by_domain(String.to_existing_atom(domain))

      search = params["search"] ->
        Registry.search(search)

      true ->
        # No filter — return domain summary, not all skills
        Registry.list_domains_summary()
    end

    {:ok, %SkillResult{
      status: :ok,
      content: format_skills_response(skills, params),
      metadata: %{skill_count: length(skills)}
    }}
  end

  # When no domain specified, return a high-level domain summary
  # to avoid dumping all skill schemas at once
  defp format_skills_response(domains, %{}) when is_list(domains) do
    """
    Available domains:
    #{Enum.map_join(domains, "\n", fn {domain, count, desc} ->
      "- #{domain} (#{count} skills): #{desc}"
    end)}

    Call get_skill with a specific domain to see available skills and their parameters.
    """
  end

  # When domain specified, return full skill definitions
  defp format_skills_response(skills, _params) do
    Jason.encode!(%{skills: Enum.map(skills, &(&1.tool_definition()))})
  end
end
```

**Behavior without a domain filter**: If the LLM calls `get_skill()` with no arguments, it receives a domain summary rather than every skill definition. This prevents the token bloat problem from reappearing:

```
Available domains:
- email (3 skills): Send, read, and search emails via Gmail
- calendar (3 skills): Create, list, and update Google Calendar events
- drive (4 skills): Read, update, list, and search files on Google Drive
- tasks (5 skills): Create, search, get, update, and archive tasks
- hubspot (3 skills): Manage contacts, deals, and notes in HubSpot CRM
- markdown (4 skills): Edit, create, search, and manage Obsidian markdown files

Call get_skill with a specific domain to see available skills and their parameters.
```

### 3.2 use_skill Execution

```
LLM calls: use_skill(skill: "email.send", arguments: {to: ["bob@co.com"], ...})
    |
    v
MetaTools.UseSkill.execute/2
    |
    v
1. Look up skill module in Registry by name "email.send"
  - Not found? -> Return error: "Unknown skill 'email.send'. Call get_skill to discover available skills."
    |
    v
2. Validate arguments against skill's parameter schema (JSON Schema validation)
   - Validation fails? -> Return error with specific field/constraint details
    |
    v
3. Check circuit breaker for the skill
  - Circuit open? -> Return error: "email.send is temporarily unavailable due to repeated failures."
    |
    v
4. Delegate to Skills.Executor.execute(skill_module, validated_args, context)
   - This is the existing execution path (Task.Supervisor, timeouts, etc.)
    |
    v
5. Return SkillResult to LLM as tool result
```

```elixir
defmodule Assistant.Skills.MetaTools.UseSkill do
  def execute(params, context) do
    skill_name = params["skill"]
    arguments = params["arguments"] || %{}

    with {:ok, skill_module} <- Registry.get_by_name(skill_name),
         :ok <- validate_arguments(skill_module, arguments),
         :ok <- check_circuit_breaker(skill_name),
         {:ok, result} <- Executor.execute(skill_module, arguments, context) do
      {:ok, result}
    else
      {:error, :not_found} ->
        {:ok, %SkillResult{
          status: :error,
          content: "Unknown skill '#{skill_name}'. Call get_skill to discover available skills."
        }}

      {:error, :validation, details} ->
        {:ok, %SkillResult{
          status: :error,
          content: "Invalid arguments for '#{skill_name}': #{format_validation_errors(details)}"
        }}

      {:error, :circuit_open} ->
        {:ok, %SkillResult{
          status: :error,
          content: "'#{skill_name}' is temporarily unavailable. Please try again later."
        }}

      {:error, reason} ->
        {:ok, %SkillResult{
          status: :error,
          content: "Failed to execute '#{skill_name}': #{inspect(reason)}"
        }}
    end
  end
end
```

**Error results are `:ok` tuples**: Even when a skill fails or arguments are invalid, `use_skill` returns `{:ok, %SkillResult{status: :error, ...}}`. This is intentional — the meta-tool executed successfully; it is the inner skill that failed. The LLM receives the error as a tool result and can decide whether to retry, ask the user for clarification, or report the failure. The `{:error, ...}` return from `execute/2` is reserved for infrastructure failures (e.g., the executor itself crashed).

---

## 4. Agentic Loop Design

> **SUPERSEDED**: This section describes the original single-loop pattern where one LLM
> calls both `get_skill` and `use_skill`. This has been replaced by the multi-agent
> orchestration pattern in `sub-agent-orchestration.md`. Retained here for reference
> and as a fallback for the `:single_loop` feature flag mode.

### 4.1 Loop Architecture

The orchestration engine runs a turn-based agent loop. Each "turn" is one user message and the sequence of LLM calls + tool executions needed to produce a final response.

```
                     User Message
                          |
                          v
                +-------------------+
                | Load Conversation |
                | Context + Memory  |
                +-------------------+
                          |
                          v
            +---------------------------+
            |     Build LLM Request     |
            | system prompt + history   |
            | + memory + 2 tool defs    |
            +---------------------------+
                          |
                          v
            +---------------------------+
     +----->|   Call OpenRouter API      |
     |      +---------------------------+
     |                |
     |                v
     |      +-------------------+
     |      | Response Type?    |
     |      +-------------------+
     |         |              |
     |         v              v
     |     text_response   tool_call(s)
     |         |              |
     |         v              v
     |      DONE         +------------------+
     |      (send to     | For each call:   |
     |       user)       | Execute meta-tool|
     |                   | (get_skill or    |
     |                   |  use_skill)      |
     |                   +------------------+
     |                        |
     |                        v
     |                   Collect all results
     |                        |
     |                        v
     |                   Append tool results
     |                   to message history
     |                        |
     |                        v
     |                   Check limits
     |                    |          |
     |                    v          v
     |                  OK       TRIPPED
     |                    |          |
     +--------------------+          v
                               Circuit breaker
                               response (ask
                               user to continue)
```

### 4.2 Loop State

The engine GenServer maintains per-conversation loop state:

```elixir
defmodule Assistant.Orchestrator.LoopState do
  @type t :: %__MODULE__{
    conversation_id: String.t(),
    user_id: String.t(),
    channel: atom(),
    turn_number: non_neg_integer(),

    # Messages for the current LLM context window
    messages: [map()],

    # Turn-scoped counters (reset per user message)
    turn_tool_calls: non_neg_integer(),
    turn_get_skill_calls: non_neg_integer(),
    turn_use_skill_calls: non_neg_integer(),

    # Conversation-scoped counters (sliding window)
    conversation_tool_calls: non_neg_integer(),
    conversation_window_start: DateTime.t(),

    # Accumulated results for progress reporting
    completed_actions: [String.t()],

    # Circuit breaker state
    status: :running | :paused | :completed | :error
  }
end
```

### 4.3 Loop Implementation

```elixir
defmodule Assistant.Orchestrator.Engine do
  use GenServer

  def handle_cast({:new_message, message}, state) do
    state = %{state |
      turn_tool_calls: 0,
      turn_get_skill_calls: 0,
      turn_use_skill_calls: 0,
      completed_actions: []
    }

    # Append user message to history
    messages = state.messages ++ [%{role: "user", content: message.content}]

    # Run the agent loop
    case run_loop(messages, state) do
      {:done, final_message, new_state} ->
        persist_conversation(new_state)
        send_response(final_message, new_state)
        {:noreply, new_state}

      {:paused, progress_summary, new_state} ->
        persist_conversation(new_state)
        send_response(progress_summary, new_state)
        {:noreply, new_state}

      {:error, reason, new_state} ->
        persist_conversation(new_state)
        send_error_response(reason, new_state)
        {:noreply, new_state}
    end
  end

  defp run_loop(messages, state) do
    # Check limits before calling LLM
    case Limits.check(state) do
      :ok ->
        call_llm_and_process(messages, state)

      {:tripped, :turn_limit, progress} ->
        {:paused, build_progress_message(progress, state), state}

      {:tripped, :conversation_limit, _} ->
        {:paused, build_conversation_limit_message(state), state}
    end
  end

  defp call_llm_and_process(messages, state) do
    tool_defs = build_tool_definitions()

    case LLMClient.chat(messages, tools: tool_defs) do
      {:ok, %{type: :text, content: text}} ->
        new_messages = messages ++ [%{role: "assistant", content: text}]
        {:done, text, %{state | messages: new_messages}}

      {:ok, %{type: :tool_calls, calls: calls}} ->
        {results, new_state} = execute_tool_calls(calls, state)
        new_messages = messages
          ++ [%{role: "assistant", tool_calls: calls}]
          ++ Enum.map(results, fn {call, result} ->
            %{role: "tool", tool_call_id: call.id, content: result.content}
          end)
        run_loop(new_messages, %{new_state | messages: new_messages})

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  defp execute_tool_calls(calls, state) do
    Enum.map_reduce(calls, state, fn call, acc_state ->
      {result, new_state} = execute_single_tool_call(call, acc_state)
      {{call, result}, new_state}
    end)
  end

  defp execute_single_tool_call(%{name: "get_skill"} = call, state) do
    result = MetaTools.GetSkill.execute(call.arguments, build_context(state))
    new_state = %{state |
      turn_tool_calls: state.turn_tool_calls + 1,
      turn_get_skill_calls: state.turn_get_skill_calls + 1
    }
    {elem(result, 1), new_state}
  end

  defp execute_single_tool_call(%{name: "use_skill"} = call, state) do
    result = MetaTools.UseSkill.execute(call.arguments, build_context(state))
    action_desc = "#{call.arguments["skill"]}(#{summarize_args(call.arguments["arguments"])})"
    new_state = %{state |
      turn_tool_calls: state.turn_tool_calls + 1,
      turn_use_skill_calls: state.turn_use_skill_calls + 1,
      completed_actions: state.completed_actions ++ [action_desc]
    }
    {elem(result, 1), new_state}
  end

  defp build_tool_definitions do
    [
      MetaTools.GetSkill.tool_definition(),
      MetaTools.UseSkill.tool_definition()
    ]
  end
end
```

### 4.4 Parallel Tool Calls

OpenRouter (and the OpenAI API format) supports returning multiple tool calls in a single response. The LLM may call both `get_skill` and `use_skill` in one turn, or call `use_skill` multiple times (e.g., creating multiple tasks).

**Handling strategy**:

```elixir
defp execute_tool_calls(calls, state) do
  # Separate get_skill (discovery) from use_skill (action) calls
  {discovery_calls, action_calls} = Enum.split_with(calls, fn c -> c.name == "get_skill" end)

  # Execute discovery calls first (they inform action calls)
  {discovery_results, state} = Enum.map_reduce(discovery_calls, state, fn call, acc ->
    {result, new_acc} = execute_single_tool_call(call, acc)
    {{call, result}, new_acc}
  end)

  # Execute action calls in parallel (via Task.Supervisor)
  {action_results, state} = execute_actions_parallel(action_calls, state)

  {discovery_results ++ action_results, state}
end

defp execute_actions_parallel(calls, state) when length(calls) <= 1 do
  # Single call — execute directly
  Enum.map_reduce(calls, state, fn call, acc ->
    {result, new_acc} = execute_single_tool_call(call, acc)
    {{call, result}, new_acc}
  end)
end

defp execute_actions_parallel(calls, state) do
  # Multiple action calls — execute concurrently via Task.Supervisor
  tasks = Enum.map(calls, fn call ->
    Task.Supervisor.async_nolink(
      Assistant.Skills.Executor.TaskSupervisor,
      fn -> MetaTools.UseSkill.execute(call.arguments, build_context(state)) end,
      timeout: 30_000
    )
  end)

  results = Task.yield_many(tasks, timeout: 30_000)
  paired_results = Enum.zip(calls, results)
    |> Enum.map(fn {call, {_task, result}} ->
      case result do
        {:ok, {:ok, skill_result}} -> {call, skill_result}
        {:ok, {:error, reason}} -> {call, error_result(reason)}
        {:exit, reason} -> {call, error_result({:task_crashed, reason})}
        nil -> {call, error_result(:timeout)}
      end
    end)

  new_state = %{state |
    turn_tool_calls: state.turn_tool_calls + length(calls),
    turn_use_skill_calls: state.turn_use_skill_calls + length(calls)
  }

  {paired_results, new_state}
end
```

---

## 5. Circuit Breaker and Limits

> **PARTIALLY SUPERSEDED**: Skill-level circuit breakers (5.4) and the "continue?" pattern
> (5.2-5.3) remain valid. The three-tier limit system (5.1) has been extended to a
> four-level hierarchy in `sub-agent-orchestration.md` Section 7.

### 5.1 Three-Tier Limit System

The limit system prevents infinite loops, runaway tool calling, and resource exhaustion. It operates at three scopes:

| Tier | Scope | What It Limits | Default | Reset |
|------|-------|----------------|---------|-------|
| **1** | Per-skill execution | Individual skill runtime | 30s timeout | Per execution |
| **2** | Per-turn | Tool calls within one user message | 10 total calls | Each user message |
| **3** | Per-conversation | Tool calls within a sliding window | 50 calls / 5 min | Sliding window |

### 5.2 Turn Limit Behavior (The "Continue?" Pattern)

When the turn limit trips, the assistant does not simply error. Instead, it presents a **progress report** and asks the user whether to continue:

```
I've made progress but haven't finished yet. Here's what I've done so far:

- Searched for overdue tasks (found 3)
- Updated "Q1 Report" status to in_progress
- Sent reminder email to Bob about the report

I still need to:
- Update the calendar event with the new deadline
- Create a subtask for the review

Would you like me to continue?
```

The "continue" pattern is critical for user trust. The assistant is transparent about what it has done and what remains, and the user retains control.

**Implementation**:

```elixir
defmodule Assistant.Orchestrator.Limits do
  @turn_max_tool_calls 10
  @conversation_max_tool_calls 50
  @conversation_window_ms 300_000  # 5 minutes

  def check(state) do
    cond do
      state.turn_tool_calls >= @turn_max_tool_calls ->
        {:tripped, :turn_limit, %{
          completed: state.completed_actions,
          remaining_hint: "Turn limit reached after #{state.turn_tool_calls} tool calls"
        }}

      conversation_limit_exceeded?(state) ->
        {:tripped, :conversation_limit, %{
          window_calls: state.conversation_tool_calls,
          window_ms: @conversation_window_ms
        }}

      true ->
        :ok
    end
  end

  defp conversation_limit_exceeded?(state) do
    elapsed = DateTime.diff(DateTime.utc_now(), state.conversation_window_start, :millisecond)
    if elapsed > @conversation_window_ms do
      false  # Window expired, reset counter
    else
      state.conversation_tool_calls >= @conversation_max_tool_calls
    end
  end
end
```

### 5.3 User "Continue" Handling

When the user says "yes, continue" (or similar), the orchestrator resumes the loop from where it paused:

```elixir
def handle_cast({:new_message, %{content: "continue"} = _msg}, %{status: :paused} = state) do
  # Reset turn counters but preserve conversation counters
  state = %{state |
    turn_tool_calls: 0,
    turn_get_skill_calls: 0,
    turn_use_skill_calls: 0,
    status: :running
  }

  # Resume loop from current message history
  case run_loop(state.messages, state) do
    # ... same handling as new_message
  end
end
```

The LLM receives the prior context (including all completed actions and their results) and can pick up where it left off. The system prompt should include guidance about continuation:

```
You were previously working on a task and paused at the tool call limit.
The user has asked you to continue. Review the conversation history to see
what you've already done and continue from where you left off. Do not
repeat actions that were already completed.
```

### 5.4 Skill-Level Circuit Breakers

Individual skills have circuit breakers managed by `Assistant.Resilience.CircuitBreaker` (GenServer per skill). The `use_skill` meta-tool checks the circuit breaker before delegating to the executor:

```
State: CLOSED (normal)
  -> Skill fails -> increment failure count
  -> failure_count >= threshold (5) -> transition to OPEN

State: OPEN (rejecting calls)
  -> All use_skill calls for this skill return error immediately
  -> After recovery_timeout (60s) -> transition to HALF_OPEN

State: HALF_OPEN (testing)
  -> Allow one call through
  -> Success -> transition to CLOSED (reset counter)
  -> Failure -> transition to OPEN (restart recovery timer)
```

The circuit breaker state is persisted to the database so it survives process crashes (OTP supervisor restarts the GenServer, which loads persisted state).

---

## 6. Context Assembly

> **PARTIALLY UPDATED**: The context assembly principles and token budgets remain valid.
> The system prompt structure (6.1) evolves to include CLI command summaries instead of
> two-tool instructions. See `markdown-skill-system.md` Section 6 for `--help` text format.

### 6.1 System Prompt Structure

The system prompt is assembled per conversation turn and includes:

```
[1. Identity and instructions]
You are a helpful AI assistant. You communicate through skills — specialized
capabilities you can discover and use.

[2. Skill instructions (CLI-first mode)]
You execute skills by outputting CLI commands inside ```cmd fenced blocks.

Workflow:
1. Figure out which skill relates to the user's request
2. If you know the skill name and flags, output the command directly
3. If unsure, use --help: output the skill name with --help
4. Read the result and respond to the user

Example:
```cmd
email.send --to bob@co.com --subject "Q1 Report" --body "Here is the report."
```

For help on any skill:
```cmd
tasks.search --help
```

Important:
- Always wrap commands in ```cmd fenced blocks
- You can output multiple commands in one response
- If a command fails, read the error — it tells you which flags are wrong

[3. Available skills (lightweight, always included)]
Email:     email.send, email.search, email.read, email.draft
Tasks:     tasks.create, tasks.search, tasks.get, tasks.update, tasks.delete
Calendar:  calendar.create, calendar.list, calendar.update
Drive:     drive.read, drive.update, drive.list, drive.search
Memory:    memory.save, memory.search
Markdown:  markdown.edit, markdown.create, markdown.search
System:    build_skill

Use `<skill_name> --help` for details.

[4. User context]
User: {display_name} ({channel})
Timezone: {timezone}

[5. Active task summary (lightweight, from task management integration)]
Active tasks: 5 total, 2 overdue (highest priority: "Finalize Q1 report")

[6. Memory context (FTS + structured filter retrieval)]
Relevant memories:
- Bob prefers email for non-urgent communication
- Q1 report deadline was extended to Feb 28
```

### 6.2 Token Budget

| Component | Token Estimate | Notes |
|-----------|---------------|-------|
| Identity + instructions | ~300 | Static, cached |
| Two-tool definitions | ~400 | Static, cached |
| Domain list | ~50 | Static, changes only on skill registration |
| User context | ~50 | Per-conversation |
| Task summary | ~50-100 | Per-turn, lightweight |
| Memory context | ~200-500 | Per-turn, FTS + structured filter retrieval |
| Conversation history | ~2,000-6,000 | Sliding window, managed by ContextBuilder |
| **Total** | **~3,000-7,000** | |

Compare to the N-tool approach: if 20 tool schemas average 200 tokens each, that is 4,000 tokens for tool definitions alone. The two-tool approach saves ~3,600 tokens per request, which can be used for richer conversation history and memory context.

### 6.3 Conversation History Management

The `ContextBuilder` manages the sliding window of conversation history within a token budget. Tool call traces (from the memory system design) are included in the history:

```elixir
defmodule Assistant.Orchestrator.Context do
  @max_context_tokens 8_000
  @reserved_for_system 1_000
  @reserved_for_response 2_000
  @available_for_history @max_context_tokens - @reserved_for_system - @reserved_for_response

  def build(conversation_id, user_message) do
    system_prompt = build_system_prompt(conversation_id)
    memory_context = Memory.ContextBuilder.relevant_memories(conversation_id, user_message)
    task_summary = build_task_summary(conversation_id)

    history = Memory.Store.recent_messages(
      conversation_id,
      token_budget: @available_for_history - token_count(memory_context) - token_count(task_summary)
    )

    %{
      system: system_prompt <> memory_context <> task_summary,
      messages: history ++ [%{role: "user", content: user_message}],
      tools: [MetaTools.GetSkill.tool_definition(), MetaTools.UseSkill.tool_definition()]
    }
  end
end
```

---

## 6A. Prompt Caching Strategy

> **Added**: Detailed OpenRouter/Anthropic prompt caching design for maximizing cache hits.

### 6A.1 Cache Architecture

**Goal**: Maximize prompt cache hits by keeping the message prefix stable across all turns in a conversation and across conversations.

**Key constraints** (from OpenRouter docs, Feb 2026):
- Cache breakpoints (`cache_control: {type: "ephemeral"}`) can be placed on text content in system and user messages
- Anthropic allows max **4 breakpoints** per request
- Minimum ~1,024-4,096 tokens to create a cache entry (varies by model)
- Default TTL: 5 minutes. Extended TTL: 1 hour (costs 2x for writes, but reads are 0.1x)
- Tool definitions are part of the request prefix that benefits from caching but do NOT support direct `cache_control` breakpoints

**Why two tools enables caching**: With exactly 2 tool definitions that never change, the entire `tools` array is stable. Adding or removing skills does NOT change the tools payload — skills are registered internally, not as OpenRouter tools. This means the prefix (system prompt + tools) is identical across every API call from every conversation.

### 6A.2 Message Payload Structure

```json
{
  "model": "anthropic/claude-sonnet-4-20250514",
  "messages": [
    {
      "role": "system",
      "content": [
        {
          "type": "text",
          "text": "<<SYSTEM_PROMPT: identity, rules, domain knowledge, user context>>",
          "cache_control": {"type": "ephemeral", "ttl": "1h"}
        }
      ]
    },
    {
      "role": "user",
      "content": [
        {
          "type": "text",
          "text": "<<INJECTED_CONTEXT: active tasks summary + relevant memories + conversation history>>",
          "cache_control": {"type": "ephemeral"}
        },
        {
          "type": "text",
          "text": "<<CURRENT_USER_MESSAGE or TOOL_RESULTS>>"
        }
      ]
    }
  ],
  "tools": [
    {"type": "function", "function": {"name": "get_skill", ...}},
    {"type": "function", "function": {"name": "use_skill", ...}}
  ]
}
```

### 6A.3 Breakpoint Placement

| # | Location | Scope | Estimated Tokens | TTL |
|---|----------|-------|-----------------|-----|
| 1 | System prompt (end) | All conversations, all users | 2,000-4,000 | 1 hour |
| 2 | Injected context (end) | Per conversation, per agent loop iteration | 500-5,000 | 5 min |
| 3 | (Reserved) | Future: large document injection for file skills | — | — |
| 4 | (Reserved) | Future: large skill result re-injection | — | — |

We use 2 of the 4 available breakpoints, leaving headroom for future optimization.

**Breakpoint 1 (system prompt)** — The highest-value cache. The system prompt contains identity, instructions, domain knowledge, and user-specific context (name, timezone, date). It changes at most once per day (date rollover). With 1-hour TTL, every API call within an hour across all conversations hits this cache. For a ~3,000 token system prompt:
- Write cost: 2x = 6,000 token-equivalents (one-time per hour)
- Read cost: 0.1x = 300 token-equivalents (per subsequent call)
- Break-even: 2 calls. Everything after the 2nd call in an hour saves 90%.

**Breakpoint 2 (injected context)** — Stable within an agent loop iteration. When the LLM calls a tool and the engine feeds the result back, the prefix up to the context block is identical. With default 5-min TTL:
- Multi-step tool chains (common: get_skill -> use_skill -> text) get 2+ cache hits per user message
- Different user messages within 5 minutes share the conversation history prefix

### 6A.4 Request Builder

```elixir
defmodule Assistant.Orchestrator.RequestBuilder do
  # Tool definitions compiled at module load — never change at runtime
  @get_skill_def Assistant.Skills.MetaTools.GetSkill.tool_definition()
  @use_skill_def Assistant.Skills.MetaTools.UseSkill.tool_definition()
  @tools [@get_skill_def, @use_skill_def]

  @doc """
  Build an OpenRouter API request with cache-optimized message structure.

  The system prompt gets a 1-hour TTL breakpoint (changes rarely).
  The context block gets a 5-min TTL breakpoint (stable within agent loop).
  New content (user message or tool results) is uncached.
  """
  def build(system_prompt, context_block, new_content, opts \\ []) do
    %{
      model: opts[:model] || default_model(),
      messages: [
        %{
          role: "system",
          content: [
            %{type: "text", text: system_prompt,
              cache_control: %{type: "ephemeral", ttl: "1h"}}
          ]
        },
        %{
          role: "user",
          content: [
            %{type: "text", text: context_block,
              cache_control: %{type: "ephemeral"}}
            | format_new_content(new_content)
          ]
        }
      ],
      tools: @tools
    }
  end

  defp format_new_content(content) when is_binary(content) do
    [%{type: "text", text: content}]
  end

  defp format_new_content(content) when is_list(content) do
    # Tool results, multi-part messages, etc.
    Enum.map(content, fn
      %{role: "tool"} = msg -> %{type: "text", text: format_tool_result(msg)}
      text when is_binary(text) -> %{type: "text", text: text}
    end)
  end
end
```

### 6A.5 Agent Loop Cache Behavior

Within a single user turn, the agent loop may call the LLM multiple times:

```
Turn N, LLM Call 1:
  [system(1h CACHED) | context+history(5min WRITE) | user_msg]
  -> LLM returns: get_skill(domain: "tasks")
  -> Engine: registry lookup, return skill list

Turn N, LLM Call 2:
  [system(1h CACHED) | context+history(5min CACHED) | user_msg + get_skill_result]
  -> System: CACHE HIT (same as all calls this hour)
  -> Context: CACHE HIT (identical prefix within this agent loop)
  -> LLM returns: use_skill(skill: "tasks.create", arguments: {...})
  -> Engine: execute skill, return result

Turn N, LLM Call 3:
  [system(1h CACHED) | context+history(5min CACHED) | user_msg + get_skill_result + use_skill_result]
  -> Both breakpoints: CACHE HIT
  -> LLM returns: text response to user
```

**Cache hit ratio per turn**: For a 3-call agent loop, calls 2 and 3 hit both breakpoints = 67% hit rate on context, 100% hit rate on system prompt.

### 6A.6 Cache Monitoring

Track cache performance via Telemetry events:

```elixir
:telemetry.execute(
  [:assistant, :openrouter, :cache],
  %{
    input_tokens: usage.input_tokens,
    cache_creation_tokens: usage.cache_creation_input_tokens || 0,
    cache_read_tokens: usage.cache_read_input_tokens || 0,
    cache_hit_ratio: calculate_hit_ratio(usage)
  },
  %{conversation_id: conv_id, model: model, loop_iteration: iteration}
)
```

**Target metrics**:
- System prompt cache hit ratio: >95% (misses only on hourly TTL expiry)
- Context cache hit ratio: >60% (misses on first call per turn, hits on subsequent loop iterations)
- Overall token savings: 40-60% reduction in billed input tokens vs no caching

### 6A.7 System Prompt Design for Caching

The system prompt must be structured with stable content first:

```
[STABLE — changes only on code deployment]
Identity, core rules, two-tool instructions, domain knowledge list,
skill usage hints

[SEMI-STABLE — changes at most daily]
Current date, user display name, timezone

[END — cache breakpoint here]
```

The user-specific section (name, timezone, date) is small (~50 tokens) and changes at most once per day. For same-day conversations across the same user, the system prompt is fully cached. Different users cause a cache miss on the user-specific tail, but the shared prefix (identity + rules + instructions) still benefits from cache warm-up.

### 6A.8 Cost Model

Assuming Anthropic Claude Sonnet via OpenRouter, 10 user turns per conversation, average 2.5 LLM calls per turn:

| Component | Tokens | Without Caching | With Caching |
|-----------|--------|-----------------|--------------|
| System prompt (25 calls) | 3,000 x 25 = 75,000 | 75,000 input | 3,750 write + 7,200 read = 10,950 |
| Context block (25 calls, ~60% hit) | 2,000 x 25 = 50,000 | 50,000 input | 20,000 miss + 2,500 write + 3,000 read = 25,500 |
| New content (never cached) | ~500 x 25 = 12,500 | 12,500 input | 12,500 input |
| **Total** | | **137,500** | **48,950** |

**Savings**: ~64% reduction in effective input token cost per conversation.

---

## 7. Skill Registry Enhancements

> **SUPERSEDED**: The ETS-backed module registry described here is replaced by a file-based
> skill registry with hot-reload. See `markdown-skill-system.md` Section 7 for the current design:
> - Skills are discovered from markdown files on disk (not compiled Elixir modules)
> - FileSystem watcher triggers hot-reload on file changes
> - ETS still used for fast lookup, but populated from parsed markdown files
> - Domain information extracted from YAML frontmatter, not module callbacks
>
> Retained here for the `:single_loop` fallback mode.

### 7.1 Registry Interface

The existing `Assistant.Skills.Registry` needs additional query capabilities to support the two-tool pattern:

```elixir
defmodule Assistant.Skills.Registry do
  @doc "Look up a skill by its tool name (e.g., 'email.send')"
  @callback get_by_name(String.t()) :: {:ok, module()} | {:error, :not_found}

  @doc "List all skills in a given domain"
  @callback get_by_domain(atom()) :: [module()]

  @doc "Search skills by keyword in name or description"
  @callback search(String.t()) :: [module()]

  @doc "List all registered domains with skill counts and descriptions"
  @callback list_domains_summary() :: [{atom(), non_neg_integer(), String.t()}]

  @doc "List all available domain names"
  @callback list_domains() :: [atom()]
end
```

### 7.2 ETS Structure

The ETS table holds multiple lookup indices:

```elixir
# Table: :skill_registry (set, read_concurrency: true)
#
# Entries:
#   {:by_name, "email.send"} -> Assistant.Skills.Email.Send
#   {:by_domain, :email} -> [Assistant.Skills.Email.Send, ...]
#   {:domains} -> [:email, :calendar, :drive, :tasks, :hubspot, :markdown, :memory]
#   {:domain_desc, :email} -> "Send, read, and search emails via Gmail"
```

### 7.3 Domain Descriptions

Each domain has a human-readable description used in the `get_skill` domain summary. These are derived from the registered skills:

```elixir
@domain_descriptions %{
  email: "Send, read, and search emails via Gmail",
  calendar: "Create, list, and update Google Calendar events",
  drive: "Read, update, list, and search files on Google Drive",
  tasks: "Create, search, get, update, and archive tasks",
  hubspot: "Manage contacts, deals, and notes in HubSpot CRM",
  markdown: "Edit, create, search, and manage Obsidian markdown files",
  memory: "Save and search long-term memories across conversations"
}
```

### 7.4 Skill Discovery at Boot

At application startup, the registry discovers and registers all skill modules:

```elixir
defmodule Assistant.Skills.Registry do
  use GenServer

  def init(_) do
    table = :ets.new(:skill_registry, [:set, :named_table, read_concurrency: true])

    # Discover all modules implementing the Skill behaviour
    skill_modules = discover_skill_modules()

    # Register each skill
    for module <- skill_modules do
      definition = module.tool_definition()
      domain = module.domain()

      :ets.insert(table, {{:by_name, definition.name}, module})

      existing = case :ets.lookup(table, {:by_domain, domain}) do
        [{{:by_domain, ^domain}, modules}] -> modules
        [] -> []
      end
      :ets.insert(table, {{:by_domain, domain}, [module | existing]})
    end

    # Register domain list
    domains = skill_modules
      |> Enum.map(& &1.domain())
      |> Enum.uniq()
    :ets.insert(table, {{:domains}, domains})

    {:ok, %{table: table}}
  end

  defp discover_skill_modules do
    {:ok, modules} = :application.get_key(:assistant, :modules)
    Enum.filter(modules, fn mod ->
      behaviours = mod.module_info(:attributes) |> Keyword.get(:behaviour, [])
      Assistant.Skills.Skill in behaviours
    end)
  end
end
```

---

## 8. Module Structure

> **PARTIALLY SUPERSEDED**: The file layout below reflects the original JSON meta-tool design.
> The CLI-first design introduces a different module structure — see `markdown-skill-system.md`
> Section 13 for the current file layout. Key differences:
> - `meta_tools/` → replaced by `cli/` (extractor, help) + `skills/router.ex`
> - `schema_validator.ex` → handler-side validation with shared `FlagValidator` helper
> - `registry.ex` → file-based registry watching markdown directory
> - Skill definitions: one `.md` per action in `priv/skills/<domain>/<verb>.md` (SRP)
> - YAML frontmatter is minimal (`name` + `description` only)

### 8.1 New Modules (CLI-First)

| Module | Type | Purpose |
|--------|------|---------|
| `Assistant.CLI.Extractor` | Service | Extract ` ```cmd ` blocks from LLM output |
| `Assistant.CLI.Help` | Service | Generate help text from skill markdown body |
| `Assistant.Skills.Router` | Service | Tokenize + route commands to handlers |
| `Assistant.Skills.FlagValidator` | Helper | Common flag validation utilities for handlers |
| `Assistant.Skills.System.SkillBuilder` | Handler | Meta-skill for self-creating skills |
| `Assistant.Orchestrator.LoopState` | Struct | Per-conversation loop state |

### 8.2 Retained Modules (JSON fallback for `:single_loop` mode)

| Module | Type | Purpose |
|--------|------|---------|
| `Assistant.Skills.MetaTools.GetSkill` | Meta-tool | Skill discovery tool |
| `Assistant.Skills.MetaTools.UseSkill` | Meta-tool | Skill execution wrapper |
| `Assistant.Skills.SchemaValidator` | Service | JSON Schema validation for skill arguments |

### 8.3 Modified Modules

| Module | Change |
|--------|--------|
| `Assistant.Skills.Registry` | File-based discovery (markdown files, one per action) + ETS keyed by skill name |
| `Assistant.Orchestrator.Engine` | Dispatches to CLI Extractor + Router (CLI mode) or meta-tools (fallback) |
| `Assistant.Orchestrator.Context` | Build system prompt with skill listings + help instructions |
| `Assistant.Orchestrator.Limits` | Track command executions (replaces get_skill/use_skill split) |

### 8.4 File Layout (CLI-First)

```
lib/assistant/
  +-- cli/
  |   +-- extractor.ex           # ```cmd block extraction from LLM output
  |   +-- help.ex                # Help text from skill markdown body
  +-- skills/
  |   +-- router.ex              # NEW: Tokenize + route commands to handlers
  |   +-- registry.ex            # File-based registry with FileSystem watcher
  |   +-- handler.ex             # Handler behaviour: execute(flags, context)
  |   +-- flag_validator.ex      # NEW: Common validation helpers for handlers
  |   +-- skill_definition.ex    # NEW: SkillDefinition struct
  |   +-- validator.ex           # NEW: Skill file validation
  |   +-- executor.ex            # Skill execution (Task.Supervisor, timeouts)
  |   +-- result.ex              # Skill result struct
  |   +-- context.ex             # Skill execution context
  |   +-- handlers/              # Built-in skill handlers (one per action)
  |   |   +-- email/
  |   |   |   +-- send.ex        # email.send handler
  |   |   |   +-- search.ex      # email.search handler
  |   |   |   +-- read.ex        # email.read handler
  |   |   |   +-- draft.ex       # email.draft handler
  |   |   +-- tasks/
  |   |   +-- calendar/
  |   |   +-- drive/
  |   |   +-- hubspot/
  |   |   +-- memory/
  |   |   +-- markdown/
  |   |   +-- system/
  |   |       +-- skill_builder.ex
  |   +-- meta_tools/            # RETAINED: JSON fallback for :single_loop mode
  |       +-- get_skill.ex
  |       +-- use_skill.ex
priv/skills/                     # Skill definitions (one .md per action, SRP)
  +-- email/
  |   +-- send.md                # email.send
  |   +-- search.md              # email.search
  |   +-- read.md                # email.read
  |   +-- draft.md               # email.draft
  +-- tasks/
  |   +-- create.md              # tasks.create
  |   +-- search.md              # tasks.search
  +-- calendar/
  +-- drive/
  +-- hubspot/
  +-- memory/
  +-- markdown/
  +-- system/
  |   +-- build_skill.md         # build_skill
  +-- markdown.md                # markdown edit|create|search
```

---

## 9. JSON Schema Validation

> **SUPERSEDED**: JSON Schema validation is replaced by YAML frontmatter-driven flag
> validation in the CLI parser. See `markdown-skill-system.md` Section 5.4 for flag
> validation (type checking, enum enforcement, required flag enforcement).
>
> Retained here for the `:single_loop` fallback mode.

### 9.1 Purpose

When the LLM calls `use_skill`, the `arguments` must be validated against the skill's declared parameter schema before execution. This prevents malformed data from reaching skill implementations.

### 9.2 Validation Module

```elixir
defmodule Assistant.Skills.SchemaValidator do
  @doc """
  Validates arguments against a skill's JSON Schema parameter definition.
  Returns {:ok, validated_args} or {:error, :validation, details}.
  """
  def validate(arguments, schema) do
    case do_validate(arguments, schema) do
      :ok -> {:ok, arguments}
      {:error, errors} -> {:error, :validation, format_errors(errors)}
    end
  end

  defp do_validate(args, schema) do
    # Check required fields
    required = schema["required"] || []
    missing = Enum.filter(required, fn field -> not Map.has_key?(args, field) end)

    if missing != [] do
      {:error, Enum.map(missing, fn f -> "Missing required field: '#{f}'" end)}
    else
      # Check types and enum values for provided fields
      properties = schema["properties"] || %{}
      errors = Enum.flat_map(args, fn {key, value} ->
        case Map.get(properties, key) do
          nil -> ["Unknown parameter: '#{key}'"]
          prop_schema -> validate_property(key, value, prop_schema)
        end
      end)

      case errors do
        [] -> :ok
        errs -> {:error, errs}
      end
    end
  end

  defp validate_property(key, value, %{"type" => "string", "enum" => enum}) do
    if value in enum, do: [], else: ["'#{key}' must be one of: #{Enum.join(enum, ", ")}"]
  end

  defp validate_property(key, value, %{"type" => "string"}) when is_binary(value), do: []
  defp validate_property(key, _value, %{"type" => "string"}), do: ["'#{key}' must be a string"]

  defp validate_property(key, value, %{"type" => "integer"}) when is_integer(value), do: []
  defp validate_property(key, _value, %{"type" => "integer"}), do: ["'#{key}' must be an integer"]

  defp validate_property(key, value, %{"type" => "boolean"}) when is_boolean(value), do: []
  defp validate_property(key, _value, %{"type" => "boolean"}), do: ["'#{key}' must be a boolean"]

  defp validate_property(key, value, %{"type" => "array"}) when is_list(value), do: []
  defp validate_property(key, _value, %{"type" => "array"}), do: ["'#{key}' must be an array"]

  defp validate_property(key, value, %{"type" => "object"}) when is_map(value), do: []
  defp validate_property(key, _value, %{"type" => "object"}), do: ["'#{key}' must be an object"]

  defp validate_property(_, _, _), do: []  # Unknown schema type — pass through
end
```

**Design note**: This is intentionally a lightweight validator, not a full JSON Schema validator. It checks required fields, basic types, and enum values — the most common LLM mistakes. A full JSON Schema library (like `ex_json_schema`) could be added later if needed, but the lightweight approach avoids a dependency and handles the 95% case.

---

## 10. LLM Interaction Patterns

> **UPDATED**: Patterns below show both JSON (original) and CLI (current) equivalents.
> In CLI-first mode, the LLM outputs commands directly without separate discovery steps.

### 10.1 Common Patterns

**Pattern 1: Known skill, direct execution**

In CLI mode, the LLM typically outputs commands directly without a discovery step:

```
Turn 1:
  User: "Create a task to review PR #42"
  LLM:
    ```cmd
    tasks.create --title "Review PR #42"
    ```

Turn 2:
  User: "Also add a task to deploy the fix"
  LLM:
    ```cmd
    tasks.create --title "Deploy fix for PR #42"
    ```
```

**Pattern 2: Cross-domain orchestration**

Complex requests that span domains — multiple commands in one response:

```
User: "Send Bob the overdue tasks report and create a calendar event for the review"

LLM:
  ```cmd
  tasks.search --status overdue
  ```
  -> Engine returns overdue tasks

LLM:
  ```cmd
  email.send --to bob@co.com --subject "Overdue Tasks" --body "Here are the overdue tasks: ..."
  calendar.create --title "Task Review" --date 2026-02-20 --time 14:00
  ```
```

**Pattern 3: Error recovery**

When a CLI command fails validation:

```
LLM:
  ```cmd
  email.send --to bob@co.com --subject "Hi"
  ```
  -> Error: Missing required flag: --body

LLM:
  ```cmd
  email.send --to bob@co.com --subject "Hi" --body "Hello!"
  ```
  -> Success
```

**Pattern 4: Exploratory discovery**

When the user asks a vague question:

```
User: "What can you do?"
LLM:
  I can help with these areas:

  Email:     email.send, email.search, email.read, email.draft
  Tasks:     tasks.create, tasks.search, tasks.get, tasks.update, tasks.delete
  Calendar:  calendar.create, calendar.list, calendar.update
  Drive:     drive.read, drive.update, drive.list, drive.search
  Memory:    memory.save, memory.search
  Markdown:  markdown.edit, markdown.create, markdown.search

  Ask me about any of these, or I can look up details:
  ```cmd
  tasks.get --help
  ```
```

### 10.2 System Prompt Optimization

The system prompt includes skill hints to reduce unnecessary help queries:

```
Skill Quick Reference:
- tasks.create --title "..." [--priority high|medium|low] [--due DATE]
- tasks.search --query "..." [--status overdue|active|done]
- tasks.get --task_id UUID | --task_ids UUID1,UUID2 | --recent true [--limit N]
- email.send --to ADDR --subject "..." --body "..."
- email.search --query "..." [--from ADDR] [--after DATE]
- calendar.create --title "..." --date DATE --time TIME
- memory.save --content "..." [--tags tag1,tag2] [--category preference|fact|decision]
- memory.search --query "..."

Use `<skill_name> --help` for full flag details.
```

This gives the LLM "muscle memory" for common skills while the `--help` system handles unfamiliar operations.

---

## 11. Message Persistence (Tool Call Traces)

> **UPDATED**: In CLI-first mode, command executions are persisted differently from JSON
> tool calls. The LLM outputs text containing ` ```cmd ` blocks; the engine extracts,
> executes, and injects results back into the conversation. The persistence format changes
> from tool_call/tool message pairs to assistant text + injected command results.

### 11.1 Recording CLI Command Executions

In CLI-first mode, commands are embedded in the assistant's text output. The conversation history records:

**LLM output with command**:

```elixir
# Assistant message contains text + commands (stored as-is)
%{
  role: "assistant",
  content: """
  I'll send that email now.

  ```cmd
  email send --to bob@co.com --subject "Q1 Report" --body "Here is the report."
  ```
  """
}

# Command result injected as a system/user message (engine-generated)
%{
  role: "user",
  content: "[Command Result: email send]\nEmail sent successfully to bob@co.com\nMessage ID: msg_abc123"
}
```

**JSON fallback mode** (`:single_loop`) uses the original tool_call/tool message pairs:

```elixir
# LLM's tool call message (role: "assistant", contains tool_calls)
%{
  role: "assistant",
  tool_calls: [%{
    id: "call_abc123",
    type: "function",
    function: %{name: "get_skill", arguments: ~s({"domain": "email"})}
  }]
}

# Tool result message (role: "tool")
%{
  role: "tool",
  tool_call_id: "call_abc123",
  content: ~s({"domain": "email", "skills": [...]})
}
```

### 11.2 Skill Execution Logging

The existing `skill_executions` table records each inner skill execution (the actual `email.send`, `tasks.create`, etc.), not the meta-tool wrapper. The `use_skill` meta-tool creates the execution log entry:

```elixir
# In MetaTools.UseSkill.execute/2, before delegating to Executor:
execution = %SkillExecution{
  conversation_id: context.conversation_id,
  skill_id: skill_name,
  parameters: arguments,
  status: "running",
  started_at: DateTime.utc_now()
}
|> Repo.insert!()

# After execution completes:
Repo.update!(execution, %{
  status: if(result.status == :ok, do: "completed", else: "failed"),
  result: %{content: result.content, metadata: result.metadata},
  error_message: if(result.status == :error, do: result.content),
  duration_ms: elapsed_ms,
  completed_at: DateTime.utc_now()
})
```

---

## 12. Testing Strategy

### 12.1 Unit Tests

**MetaTools.GetSkill**:
- Returns domain summary when no filter provided
- Returns skill definitions when domain specified
- Returns matching skills when search keyword provided
- Handles unknown domain gracefully
- Populates domain enum from registry

**MetaTools.UseSkill**:
- Delegates to correct skill module via registry
- Validates arguments against skill schema
- Returns structured error for unknown skill name
- Returns structured error for invalid arguments
- Checks circuit breaker before execution
- Creates skill_execution log entry

**SchemaValidator**:
- Catches missing required fields
- Catches type mismatches (string vs array, etc.)
- Validates enum values
- Passes valid arguments through
- Handles empty schema gracefully

### 12.2 Integration Tests

**Agent loop with two tools**:
- Full turn: user message -> get_skill -> use_skill -> text response
- Direct use_skill (skipping get_skill when skill is known)
- Cross-domain turn: multiple get_skill + use_skill calls
- Error recovery: invalid arguments -> retry with correct arguments
- Turn limit trip: progress report + continue pattern
- Parallel tool calls: multiple use_skill calls in one LLM response

**Circuit breaker integration**:
- Skill fails N times -> circuit opens -> use_skill returns error
- Circuit in half-open -> single call passes through -> success resets

### 12.3 Behavioral Tests (LLM Integration)

These test the LLM's ability to use the two-tool pattern effectively:

- "Send an email" -> LLM discovers email skills then sends
- "Create a task" -> LLM discovers task skills then creates
- "What can you do?" -> LLM calls get_skill() and summarizes domains
- "Do X, Y, and Z" -> LLM chains multiple tool calls across domains
- Error recovery -> LLM corrects arguments after validation failure

---

## 13. Migration Path

### 13.1 From N-Tool to CLI-First

> **UPDATED**: The migration path now leads to CLI-first, not JSON meta-tools. The two-tool
> pattern is retained as `:single_loop` fallback.

The migration proceeds in two stages:

**Stage 1: CLI parser + file registry (Phase 1)**
1. **Create CLI modules**: `Parser`, `Extractor`, `HelpGenerator`
2. **Create FileRegistry**: File-based skill registry with FileSystem watcher
3. **Write skill markdown files**: One `.md` per domain in `priv/skills/`
4. **Create handler modules**: One handler per domain implementing `execute(flags, context)`
5. **Update Engine**: Detect ` ```cmd ` blocks in LLM output, route to CLI Parser
6. **Update Context**: System prompt with CLI command summary + `--help` instructions

**Stage 2: Self-creating skills (Phase 2+)**
1. **Add SkillBuilder**: Meta-skill that writes markdown files with YAML frontmatter
2. **Add markdown content indexer**: PostgreSQL FTS for markdown content search
3. **Add scheduled skills**: Quantum integration for cron-scheduled skill execution

### 13.2 Feature Flag

A configuration flag selects the orchestration mode:

```elixir
config :assistant, Assistant.Orchestrator.Engine,
  tool_mode: :multi_agent  # :multi_agent | :single_loop | :direct
```

| Mode | Description | LLM Interface | Skill Definition |
|------|-------------|---------------|------------------|
| `:multi_agent` | **Default**. Orchestrator + sub-agents, CLI commands. | CLI commands in ` ```cmd ` blocks | Markdown files with YAML frontmatter |
| `:single_loop` | JSON meta-tool fallback. | JSON tool calls (get_skill/use_skill) | Elixir modules with `tool_definition/0` |
| `:direct` | N-tool mode (all skills as JSON tools). | JSON tool calls (one per skill) | Elixir modules with `tool_definition/0` |

The `:single_loop` mode retains the original two-tool architecture as a fallback. The `:multi_agent` mode with CLI commands is the primary design. See `sub-agent-orchestration.md` for multi-agent coordination and `markdown-skill-system.md` for CLI skill definitions.

---

## 14. Integration Points

### 14.1 With Sub-Agent Orchestration

> See `sub-agent-orchestration.md` for the full multi-agent design.

In `:multi_agent` mode (default), the tools defined in this document split across two roles:
- **Orchestrator** uses `get_skill` for discovery + `dispatch_agent` / `get_agent_results` for delegation
- **Sub-agents** use `use_skill` for execution, scoped to the skills granted by the orchestrator

The `get_skill` and `use_skill` tool definitions (Sections 2-3) remain the foundation. The sub-agent orchestration adds a coordination layer above them.

### 14.2 With Task Management System

The task management skills (`tasks.create`, `tasks.search`, `tasks.get`, `tasks.update`, `tasks.delete`) register in the `:tasks` domain. In multi-agent mode, the orchestrator discovers them via `get_skill(domain: "tasks")` and dispatches a sub-agent with `skills: ["tasks.search", "tasks.update"]` etc. Individual skill implementations are unchanged.

### 14.3 With Memory System

Memory is a first-class skill domain — the LLM saves and retrieves memories through the same `get_skill`/`use_skill` interface as every other domain. No special-case memory APIs.

**Conversation-level integration**:
- Orchestrator messages (including dispatch and agent results) are stored in conversation history
- Sub-agent tool call traces are stored in `skill_executions` (not conversation messages) — see `sub-agent-orchestration.md` Section 12
- Memory extraction works on sub-agent results (same as before, different caller)
- The sliding window context builder includes orchestrator-level history within the token budget

**Memory as skills**: Two skills register in the `:memory` domain:

#### memory.save

```elixir
defmodule Assistant.Skills.Memory.Save do
  @moduledoc """
  Saves a memory entry for the user. Called when the LLM determines something
  is worth remembering long-term (facts, preferences, decisions, context).
  """
  @behaviour Assistant.Skills.Skill

  @impl true
  def tool_definition do
    %{
      name: "memory.save",
      description: "Save information to long-term memory. Use this when the user shares a preference, fact, decision, or anything worth remembering across conversations.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "content" => %{
            "type" => "string",
            "description" => "The information to remember. Write as a clear, standalone statement (e.g., 'User prefers Elixir over Ruby for backend work')."
          },
          "tags" => %{
            "type" => "array",
            "items" => %{"type" => "string"},
            "description" => "Tags for categorization and retrieval, e.g. ['preference', 'tech-stack', 'elixir']. Use lowercase, hyphenated."
          },
          "category" => %{
            "type" => "string",
            "enum" => ["preference", "fact", "decision", "goal", "relationship", "context", "instruction"],
            "description" => "High-level category. Defaults to 'context' if not specified."
          },
          "importance" => %{
            "type" => "number",
            "minimum" => 0.0,
            "maximum" => 1.0,
            "description" => "How important this memory is (0.0-1.0). Defaults to 0.5. Use higher values for explicit user instructions or critical preferences."
          }
        },
        "required" => ["content"]
      }
    }
  end

  @impl true
  def domain, do: :memory

  @impl true
  def isolation_level, do: :none
end
```

**Execution flow** (`execute/2`, implemented in CODE phase):
1. Receive `%{content, tags, category, importance}` + `%SkillContext{user_id, conversation_id}`
2. Build `%Memory.Entry{}` changeset with defaults (`category: "context"`, `importance: 0.5`, `source_type: "conversation"`)
3. Insert via `Repo.insert/1` — the `search_vector` column auto-populates (GENERATED ALWAYS AS)
4. Return `{:ok, %Result{content: "Saved: #{summary}", metadata: %{memory_id: id}}}`

**Deduplication**: Before insert, query for existing memories with high text similarity (same user, same category, FTS match on content). If a near-duplicate exists, update it instead of creating a new entry. This prevents memory bloat from repeated saves of the same information.

```elixir
# Deduplication check (simplified)
existing = Repo.one(
  from m in Memory.Entry,
    where: m.user_id == ^user_id
      and m.category == ^category
      and fragment("search_vector @@ plainto_tsquery('english', ?)", ^content),
    order_by: [desc: fragment("ts_rank(search_vector, plainto_tsquery('english', ?))", ^content)],
    limit: 1
)

case existing do
  %{id: id} = entry when ts_rank > 0.8 ->
    # Update existing memory (merge tags, update content if richer)
    update_existing(entry, params)
  _ ->
    # Insert new memory
    insert_new(params)
end
```

#### memory.search

```elixir
defmodule Assistant.Skills.Memory.Search do
  @moduledoc """
  Searches the user's long-term memories using full-text search and structured filters.
  Returns ranked results weighted by relevance and importance.
  """
  @behaviour Assistant.Skills.Skill

  @impl true
  def tool_definition do
    %{
      name: "memory.search",
      description: "Search long-term memories. Use this to recall user preferences, past decisions, facts, or context from previous conversations. Returns ranked results.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "query" => %{
            "type" => "string",
            "description" => "Natural language search query, e.g. 'preferred programming language' or 'meeting with Sarah last week'"
          },
          "tags" => %{
            "type" => "array",
            "items" => %{"type" => "string"},
            "description" => "Filter by tags. Results must match at least one tag (OR). Optional."
          },
          "category" => %{
            "type" => "string",
            "enum" => ["preference", "fact", "decision", "goal", "relationship", "context", "instruction"],
            "description" => "Filter by category. Optional."
          },
          "limit" => %{
            "type" => "integer",
            "minimum" => 1,
            "maximum" => 20,
            "description" => "Maximum number of results to return. Defaults to 5."
          },
          "min_importance" => %{
            "type" => "number",
            "minimum" => 0.0,
            "maximum" => 1.0,
            "description" => "Minimum importance threshold. Optional — useful for retrieving only high-value memories."
          }
        },
        "required" => ["query"]
      }
    }
  end

  @impl true
  def domain, do: :memory

  @impl true
  def isolation_level, do: :none
end
```

**Execution flow** (`execute/2`, implemented in CODE phase):
1. Receive `%{query, tags, category, limit, min_importance}` + `%SkillContext{user_id}`
2. Build Ecto query with dynamic filters:

```elixir
def execute(%{"query" => query} = args, %SkillContext{user_id: user_id}) do
  limit = Map.get(args, "limit", 5)

  base_query =
    from m in Memory.Entry,
      where: m.user_id == ^user_id,
      where: fragment("search_vector @@ plainto_tsquery('english', ?)", ^query),
      select: %{
        id: m.id,
        content: m.content,
        tags: m.tags,
        category: m.category,
        importance: m.importance,
        created_at: m.created_at,
        rank: fragment(
          "ts_rank(search_vector, plainto_tsquery('english', ?)) * ?",
          ^query,
          m.importance
        )
      },
      order_by: [desc: fragment(
        "ts_rank(search_vector, plainto_tsquery('english', ?)) * ?",
        ^query,
        m.importance
      )],
      limit: ^limit

  # Apply optional filters dynamically
  query_with_filters =
    base_query
    |> maybe_filter_tags(args["tags"])
    |> maybe_filter_category(args["category"])
    |> maybe_filter_importance(args["min_importance"])

  results = Repo.all(query_with_filters)

  # Update accessed_at for retrieved memories (async, non-blocking)
  memory_ids = Enum.map(results, & &1.id)
  Task.start(fn ->
    from(m in Memory.Entry, where: m.id in ^memory_ids)
    |> Repo.update_all(set: [accessed_at: DateTime.utc_now()])
  end)

  # Format results for LLM consumption
  formatted = Enum.map_join(results, "\n\n", fn m ->
    tags_str = if m.tags != [], do: " [#{Enum.join(m.tags, ", ")}]", else: ""
    "- #{m.content}#{tags_str} (#{m.category}, importance: #{m.importance})"
  end)

  case results do
    [] ->
      {:ok, %Result{content: "No memories found matching '#{query}'.", metadata: %{count: 0}}}
    _ ->
      {:ok, %Result{
        content: "Found #{length(results)} memories:\n\n#{formatted}",
        metadata: %{count: length(results), memory_ids: memory_ids}
      }}
  end
end

defp maybe_filter_tags(query, nil), do: query
defp maybe_filter_tags(query, []), do: query
defp maybe_filter_tags(query, tags) do
  from m in query, where: fragment("? && ?", m.tags, ^tags)
end

defp maybe_filter_category(query, nil), do: query
defp maybe_filter_category(query, category) do
  from m in query, where: m.category == ^category
end

defp maybe_filter_importance(query, nil), do: query
defp maybe_filter_importance(query, min) do
  from m in query, where: m.importance >= ^min
end
```

3. Return formatted results as a readable list for the LLM
4. Update `accessed_at` asynchronously for memory decay calculations

**LLM behavior with memory skills**: The system prompt instructs the LLM to proactively use memory:
- At conversation start: `memory.search --query "user preferences and context"` to pre-load relevant context
- When user shares new info: `memory.save --content "..." --category preference` inline
- When user asks "do you remember...": `memory.search --query "..."` to retrieve
- In CLI mode, the LLM can output memory commands directly — no discovery step needed

### 14.4 With Circuit Breakers

Circuit breakers operate on inner skills, not on meta-tools. The `get_skill` meta-tool never trips a circuit breaker (it only reads from the registry). The `use_skill` meta-tool checks the circuit breaker for the target skill before delegating. In multi-agent mode, additional orchestrator-level limits apply — see `sub-agent-orchestration.md` Section 7.

### 14.5 With Notification System

Skill-level notifications (e.g., task assigned, email sent) are triggered by the inner skill execution, not by the meta-tool wrapper. The meta-tool is transparent to the notification system.

### 14.6 With Voice Pipeline (OpenRouter STT + ElevenLabs TTS)

The voice stack uses OpenRouter for both STT and LLM (dual role), and ElevenLabs for TTS output. This has specific implications for the agentic loop:

**OpenRouter dual role**: The `Integrations.OpenRouter` module must support two distinct API call patterns:
1. **Chat completions with tool-calling** (existing): Text messages + tool definitions -> text/tool_call response. This is the agentic loop's primary interaction.
2. **Audio input via chat completions** (new for voice): Audio content in the user message -> the same chat completions endpoint handles transcription implicitly. OpenRouter's audio input support means STT and LLM reasoning happen in a single API call — no separate transcription step.

**Agentic loop behavior for voice**: When a message arrives from the voice channel:
1. The voice adapter converts the audio into the OpenRouter audio input format (base64 audio in the user message content array)
2. The orchestrator's `Context.build/2` includes the audio content part alongside any text
3. OpenRouter processes audio + context + tools in one call (STT + reasoning + tool-calling unified)
4. The agentic loop proceeds identically — `get_skill`/`use_skill` calls work the same regardless of input modality
5. The final text response is sent to the voice adapter, which dispatches to ElevenLabs TTS for audio output

**Key design point**: The two-tool pattern is modality-agnostic. The orchestrator LLM receives audio or text; it responds with text and/or tool calls. The meta-tools do not change. The voice adapter handles modality conversion at the channel boundary, not within the orchestration loop. In multi-agent mode, sub-agents are always text-based — they receive text missions and return text results. Only the orchestrator handles audio input.

**TTS behaviour**: ElevenLabs integration sits behind a `TTS` behaviour for testability and future provider swaps:

```elixir
defmodule Assistant.Integrations.TTS do
  @callback synthesize(text :: String.t(), opts :: keyword()) ::
    {:ok, audio_binary :: binary()} | {:error, term()}
end
```

**Context assembly adjustment for voice**: The `Context.build/2` function must handle multimodal content arrays (text + audio parts) when building the messages list for OpenRouter. This is a change to how user messages are formatted, not to the tool definitions or system prompt.

```elixir
# Text channel message
%{role: "user", content: "Send an email to Bob"}

# Voice channel message (audio input via OpenRouter)
%{role: "user", content: [
  %{type: "input_audio", input_audio: %{data: base64_audio, format: "wav"}}
]}
```

---

## 15. Open Questions

1. **~~Skill caching in conversation~~** *(Resolved by CLI-first)*: In CLI mode, the LLM outputs commands directly from the command quick reference in the system prompt. No per-conversation caching needed — the prompt itself serves as the skill cache.

2. **Command recommendation by topic**: Should the system prompt dynamically promote commands based on conversation topic? e.g., if the user mentions a task, highlight `tasks` commands. This could improve efficiency but may introduce bias. The static command quick reference (Section 10.2) may be sufficient.

3. **Streaming for long command results**: Some commands (e.g., `tasks search` returning 20 results) produce large responses. Should results be truncated with a "more" pattern, or should the LLM manage result size via flags like `--limit`? Recommend the LLM-managed approach — the `--limit` flag on search commands handles this.

4. **~~Multi-step skill chains~~** *(Resolved by CLI-first)*: In CLI mode, the LLM can output multiple commands in a single ` ```cmd ` block, one per line. The engine executes them sequentially. This naturally handles the "search then update" pattern without a special plural tool.

5. **CLI pipe composability**: The markdown-skill-system design mentions pipe composability (`tasks search --status overdue | email send --to bob`). Should this be implemented in Phase 1 or deferred? Recommend deferring — sequential commands in the same ` ```cmd ` block achieve the same result with simpler parsing.

---

## 16. Design Decision Summary

| Decision | Choice | Rationale |
|----------|--------|-----------|
| **LLM interface** | CLI commands in ` ```cmd ` fenced blocks (supersedes JSON tool calls) | LLMs produce CLI commands more reliably than nested JSON; self-documenting via `--help`. See `markdown-skill-system.md`. |
| **Skill definition format** | Markdown files with minimal YAML (`name` + `description`); body is the full definition (supersedes Elixir `tool_definition/0`) | Self-creating skills; runtime hot-reload; man-page style documentation IS the definition. See `markdown-skill-system.md`. |
| **Skill granularity** | One file per action (SRP): `email/send.md`, not `email.md` | Atomic, composable, testable, replaceable skills. Domain from directory path. |
| **Discovery mechanism** | Markdown body served as `--help` text (supersedes `get_skill` JSON schemas) | The skill file IS its own documentation; no schema-to-help translation needed. |
| **Skill registry** | File-based with FileSystem watcher + ETS cache (supersedes compile-time module discovery) | Hot-reload on file changes; compatible with self-creating skills; ETS keyed by skill name. |
| **Skill validation** | Handler-side with shared `FlagValidator` helper (supersedes centralized JSON Schema) | Keeps system simple; markdown is for humans, not machine parsing. Handlers know their own requirements. |
| Tool surface (fallback) | Two meta-tools (get_skill, use_skill) retained for `:single_loop` mode | Backward compatibility; gradual migration path. |
| Error reporting | Errors as `:ok` tuples with `:error` status | LLM receives errors as tool results and can self-correct |
| Parallel execution | Task.Supervisor for concurrent sub-agents (supersedes direct use_skill parallelism) | BEAM concurrency for multi-agent turns. See `sub-agent-orchestration.md` Section 4. |
| Circuit breaker scope | Per inner skill, not per meta-tool or CLI command | Skills may be degraded independently; CLI parser always available |
| Limit behavior | Progress report + "continue?" pattern | Transparency and user control over long-running operations |
| Domain discovery | Summary first, details on demand | Prevents token bloat from reappearing at discovery level |
| Feature flag | `:multi_agent` / `:single_loop` / `:direct` modes | Three modes: CLI multi-agent (default), JSON single-loop (fallback), direct N-tool |
| Voice input handling | Audio passed to OpenRouter as content part; loop unchanged | STT + LLM unified in one API call; CLI pattern is modality-agnostic |
| TTS output | ElevenLabs behind `TTS` behaviour | Provider-swappable; thin Req-based HTTP wrapper |
| Memory as skill | `memory.save` / `memory.search` CLI commands | No special-case APIs; same CLI interface as all domains |
| Memory search | PostgreSQL FTS (tsvector) + structured filters | Sufficient for MVP; pgvector can be added later as additive migration |
| Memory deduplication | FTS-based near-duplicate check before insert | Prevents memory bloat from repeated saves of same information |
| Memory access tracking | Async `accessed_at` update on retrieval | Supports future memory decay without blocking search results |
| **Self-creating skills** | Assistant writes markdown files via `skill build` meta-skill | No deployment needed; runtime skill creation with validation. See `markdown-skill-system.md` Section 9. |
| **Markdown content search** | PostgreSQL FTS on `markdown_index` table | Drive files can't be grep'd; FTS provides ranked full-text search. See `markdown-skill-system.md` Section 10. |
| **Scheduled skills** | YAML `schedule` field → Quantum cron integration | Declarative scheduling in skill definition; no separate config. See `markdown-skill-system.md` Section 11. |
